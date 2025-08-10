// lib/main.dart — Serverless-ish P2P Todo (Flutter)
// ---------------------------------------------------
// This app lets users create a peer-to-peer to-do list that syncs tasks between clients.
// It uses WebRTC DataChannels for direct communication, with manual copy/paste signaling (no server needed).
// Works best on the same LAN/Wi-Fi. For public internet (WAN), a relay (TURN server) will be needed.
//
// iOS: Add to Info.plist (WebRTC frameworks expect these even for data channels):
//   NSCameraUsageDescription, NSMicrophoneUsageDescription

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'P2P CRDT Todo',
    theme: ThemeData.dark(),
    home: const HomePage(),
  );
}

// -------------------- CRDT (Conflict-free Replicated Data Type) --------------------
// Op represents a single operation (add/edit/toggle/remove) on a to-do item.
// Each op is uniquely identified and timestamped for ordering and conflict resolution.
class Op {
  final String id; // op id
  final String peer; // Author peer id
  final int lamport; // lamport timestamp
  final int ts; // Wall clock (UX)
  final String type; // add|edit|toggle|remove
  final String todoId;
  final String? text;
  final bool? done;
  Op({
    required this.id,
    required this.peer,
    required this.lamport,
    required this.ts,
    required this.type,
    required this.todoId,
    this.text,
    this.done,
  });
  Map<String, dynamic> toJson() => {
    'id': id,
    'peer': peer,
    'lamport': lamport,
    'ts': ts,
    'type': type,
    'todoId': todoId,
    if (text != null) 'text': text,
    if (done != null) 'done': done,
  };
  static Op fromJson(Map<String, dynamic> j) => Op(
    id: j['id'],
    peer: j['peer'],
    lamport: j['lamport'],
    ts: j['ts'],
    type: j['type'],
    todoId: j['todoId'],
    text: j['text'],
    done: j['done'],
  );
}

class Todo {
  final String id;
  final String text;
  final bool done;
  final int ts;
  Todo(this.id, this.text, this.done, this.ts);
}

// CrdtState manages all operations and materializes the current to-do list state.
// It uses Lamport timestamps for ordering and Last-Write-Wins (LWW) for resolving conflicts.
class CrdtState {
  final Map<String, List<Op>> _opsByTodo = {};
  final Set<String> _seenOps = {};
  int lamport = 1;

  // Applies an operation if it hasn't been seen before.
  // Updates Lamport clock and stores the op for the relevant to-do item.
  bool apply(Op op) {
    if (_seenOps.contains(op.id)) return false;
    _seenOps.add(op.id);
    lamport = (lamport > op.lamport ? lamport : op.lamport) + 1;
    _opsByTodo.putIfAbsent(op.todoId, () => []).add(op);
    return true;
  }

  // Reconstructs the current to-do list from all ops, resolving conflicts.
  List<Todo> materialize() {
    final out = <Todo>[];
    for (final e in _opsByTodo.entries) {
      final ops = [...e.value];
      ops.sort((a, b) {
        final c = a.lamport.compareTo(b.lamport);
        if (c != 0) return c;
        final d = a.peer.compareTo(b.peer);
        if (d != 0) return d;
        return a.id.compareTo(b.id);
      });
      String text = '';
      bool done = false;
      bool removed = false;
      int ts = 0;
      for (final o in ops) {
        switch (o.type) {
          case 'add':
            text = o.text ?? text;
            done = o.done ?? false;
            ts = o.ts;
            break;
          case 'edit':
            if (o.text != null) text = o.text!;
            ts = o.ts;
            break;
          case 'toggle':
            if (o.done != null) done = o.done!;
            ts = o.ts;
            break;
          case 'remove':
            removed = true;
            ts = o.ts;
            break;
        }
      }
      if (!removed) out.add(Todo(e.key, text, done, ts));
    }
    out.sort((a, b) {
      final c = (a.done ? 1 : 0) - (b.done ? 1 : 0);
      return c != 0 ? c : a.ts.compareTo(b.ts);
    });
    return out;
  }

  // Serializes the CRDT state for syncing or saving.
  Map<String, dynamic> toJson() => {
    'lamport': lamport,
    'ops': _opsByTodo.values.expand((e) => e).map((o) => o.toJson()).toList(),
  };

  // Loads CRDT state from JSON (used for local storage or sync).
  void loadFromJson(Map<String, dynamic> j) {
    lamport = j['lamport'] ?? 1;
    _opsByTodo.clear();
    _seenOps.clear();
    final ops = (j['ops'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    for (final m in ops) {
      final op = Op.fromJson(m);
      _seenOps.add(op.id);
      _opsByTodo.putIfAbsent(op.todoId, () => []).add(op);
    }
  }
}

// -------------------- Manual WebRTC (copy/paste signaling) --------------------
// PeerSession holds info about a single WebRTC connection (peer).
class PeerSession {
  final String id;
  final bool caller;
  final RTCPeerConnection pc;
  RTCDataChannel? dc;
  PeerSession({required this.id, required this.caller, required this.pc});
}

// Net manages all peer connections and message broadcasting.
// Handles manual signaling (copy/paste) and relays messages between peers.
class Net {
  final _uuid = const Uuid();
  final List<PeerSession> _sessions = [];
  final _onMessage = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get messages => _onMessage.stream;

  // Creates a new WebRTC peer connection and sets up data channel/message handlers.
  Future<PeerSession> _newSession({required bool caller}) async {
    final pc = await createPeerConnection({
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
      ],
    });
    final sid = _uuid.v4().substring(0, 8);
    final sess = PeerSession(id: sid, caller: caller, pc: pc);

    pc.onDataChannel = (dc) {
      sess.dc = dc;
      dc.onMessage = (m) {
        _handleIncoming(sess.id, m.text);
      };
    };

    _sessions.add(sess);
    return sess;
  }

  // Handles incoming messages from peers, decoding JSON and forwarding to listeners.
  void _handleIncoming(String from, String text) {
    try {
      final j = jsonDecode(text);
      _onMessage.add({'from': from, 'data': j});
    } catch (_) {}
  }

  // Starts a new connection as the caller, creates a data channel, and returns the offer SDP as JSON.
  Future<String> createOffer() async {
    final s = await _newSession(caller: true);
    // Create ordered data channel now so it’s negotiated in SDP
    final dc = await s.pc.createDataChannel(
      'data',
      RTCDataChannelInit()..ordered = true,
    );
    s.dc = dc;
    dc.onMessage = (m) => _handleIncoming(s.id, m.text);

    final offer = await s.pc.createOffer();
    await s.pc.setLocalDescription(offer);
    await _waitIceComplete(s.pc);
    final local = await s.pc.getLocalDescription();
    return jsonEncode({'sid': s.id, 'type': local!.type, 'sdp': local.sdp});
  }

  // Applies the answer SDP from the remote peer to complete the connection.
  Future<void> applyAnswer(String answerJson) async {
    final j = jsonDecode(answerJson);
    final s = _sessions.firstWhere(
      (x) => x.id == j['sid'],
      orElse: () => throw Exception('Session not found'),
    );
    await s.pc.setRemoteDescription(RTCSessionDescription(j['sdp'], j['type']));
  }

  // Accepts an offer from another peer, creates an answer, and returns it as JSON.
  Future<String> acceptOfferAndCreateAnswer(String offerJson) async {
    final j = jsonDecode(offerJson);
    final s = await _newSession(caller: false);
    final remoteDesc = RTCSessionDescription(j['sdp'], j['type']);
    await s.pc.setRemoteDescription(remoteDesc);
    final answer = await s.pc.createAnswer();
    await s.pc.setLocalDescription(answer);
    await _waitIceComplete(s.pc);
    final local = await s.pc.getLocalDescription();
    return jsonEncode({
      'sid': j['sid'] ?? s.id,
      'type': local!.type,
      'sdp': local.sdp,
    });
  }

  // Broadcasts a message to all connected peers via their data channels.
  void broadcast(Map<String, dynamic> msg) {
    final str = jsonEncode(msg);
    for (final s in _sessions) {
      final dc = s.dc;
      if (dc != null && dc.state == RTCDataChannelState.RTCDataChannelOpen) {
        dc.send(RTCDataChannelMessage(str));
      }
    }
  }

  // Closes all peer connections and cleans up.
  void dispose() {
    for (final s in _sessions) {
      s.dc?.close();
      s.pc.close();
    }
    _sessions.clear();
  }
}

// Waits for ICE candidate gathering to complete (needed for reliable SDP exchange).
Future<void> _waitIceComplete(RTCPeerConnection pc) async {
  final c = Completer<void>();
  pc.onIceGatheringState = (state) {
    if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
        !c.isCompleted)
      c.complete();
  };
  // Timeout fallback to avoid hanging on some stacks
  Future.delayed(const Duration(seconds: 2), () {
    if (!c.isCompleted) c.complete();
  });
  return c.future;
}

// -------------------- App UI --------------------
// HomePage is the main screen: handles signaling, to-do list, and sync logic.
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // Unique peer ID for this client (used for op authorship and display)
  final _uuid = const Uuid();
  late final String _peerId;
  final _todoCtl = TextEditingController();

  // CRDT state for local to-do list
  final _crdt = CrdtState();
  // Net handles all peer connections and messaging
  late final Net _net;
  // Current materialized view of the to-do list
  List<Todo> _view = [];

  // Text controllers for manual signaling (copy/paste offer/answer)
  final _offerOutCtl = TextEditingController();
  final _answerInCtl = TextEditingController();
  final _offerInCtl = TextEditingController();
  final _answerOutCtl = TextEditingController();

  @override
  // Initializes peer ID, networking, message listeners, and loads local state.
  @override
  void initState() {
    super.initState();
    _peerId = 'p-' + _uuid.v4().substring(0, 6);
    _net = Net();
    _net.messages.listen((evt) {
      final data = evt['data'] as Map<String, dynamic>;
      if (data['t'] == 'op') {
        _apply(Op.fromJson(data['op']));
      } else if (data['t'] == 'sync') {
        // full snapshot
        _mergeSnapshot(data['state']);
      }
    });
    _load();
  }

  // Loads CRDT state from local storage (SharedPreferences)
  Future<void> _load() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString('state');
    if (raw != null) {
      try {
        _crdt.loadFromJson(jsonDecode(raw));
      } catch (_) {}
    }
    setState(() => _view = _crdt.materialize());
  }

  // Saves CRDT state to local storage
  Future<void> _save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('state', jsonEncode(_crdt.toJson()));
  }

  // Merges a full CRDT snapshot from a peer (used for initial sync)
  void _mergeSnapshot(Map<String, dynamic> state) {
    final snapshotOps = (state['ops'] as List).cast<Map<String, dynamic>>();
    for (final m in snapshotOps) {
      _apply(Op.fromJson(m));
    }
  }

  // Applies an op to local state, updates UI, saves, and broadcasts if local
  void _apply(Op op, {bool local = false}) {
    if (_crdt.apply(op)) {
      setState(() => _view = _crdt.materialize());
      _save();
      if (local) _net.broadcast({'t': 'op', 'op': op.toJson()});
    }
  }

  // Helper to create a new op with current Lamport timestamp and wall clock
  Op _mkOp(String type, String todoId, {String? text, bool? done}) {
    _crdt.lamport += 1;
    return Op(
      id: _uuid.v4(),
      peer: _peerId,
      lamport: _crdt.lamport,
      ts: DateTime.now().millisecondsSinceEpoch,
      type: type,
      todoId: todoId,
      text: text,
      done: done,
    );
  }

  // Adds a new to-do item
  void _addTodo(String text) {
    final id = _uuid.v4();
    _apply(_mkOp('add', id, text: text, done: false), local: true);
  }

  // Edits the text of a to-do item
  void _editTodo(Todo t, String text) {
    _apply(_mkOp('edit', t.id, text: text), local: true);
  }

  // Toggles the done state of a to-do item
  void _toggle(Todo t, bool v) {
    _apply(_mkOp('toggle', t.id, done: v), local: true);
  }

  // Removes a to-do item
  void _remove(Todo t) {
    _apply(_mkOp('remove', t.id), local: true);
  }

  // ----- Manual signaling flows (copy/paste) -----
  // Starts a new connection: creates an offer and displays it for copy/paste
  Future<void> _startOffer() async {
    final offer = await _net.createOffer();
    _offerOutCtl.text = offer;
    if (mounted) setState(() {});
  }

  // Applies the answer from the remote peer to complete the connection
  Future<void> _applyAnswer() async {
    final ans = _answerInCtl.text.trim();
    if (ans.isEmpty) return;
    await _net.applyAnswer(ans);
    Future.delayed(const Duration(milliseconds: 400), () {
      _net.broadcast({'t': 'sync', 'state': _crdt.toJson()});
    });
  }

  // Accepts a remote offer, generates an answer, and displays it for copy/paste
  Future<void> _acceptOfferGenerateAnswer() async {
    final offer = _offerInCtl.text.trim();
    if (offer.isEmpty) return;
    final answer = await _net.acceptOfferAndCreateAnswer(offer);
    _answerOutCtl.text = answer;
    if (mounted) setState(() {});
    Future.delayed(const Duration(milliseconds: 600), () {
      _net.broadcast({'t': 'sync', 'state': _crdt.toJson()});
    });
  }

  // Cleans up peer connections on exit
  @override
  void dispose() {
    _net.dispose();
    super.dispose();
  }

  // Main UI: signaling controls, to-do list, and peer ID display
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('P2P CRDT Todo'),
        actions: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Center(
              child: Text(
                _peerId,
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Connect peers (no server):',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _card(
                    children: [
                      const Text('A) Start a connection (Offer → Answer)'),
                      const SizedBox(height: 8),
                      ElevatedButton(
                        onPressed: _startOffer,
                        child: const Text('Create Offer'),
                      ),
                      const SizedBox(height: 8),
                      _monoField(
                        label: 'Your Offer (send this to the other phone)',
                        ctl: _offerOutCtl,
                        maxLines: 10,
                        copy: true,
                      ),
                      const SizedBox(height: 6),
                      _monoField(
                        label: 'Paste Remote Answer here',
                        ctl: _answerInCtl,
                        maxLines: 10,
                      ),
                      const SizedBox(height: 6),
                      ElevatedButton(
                        onPressed: _applyAnswer,
                        child: const Text('Apply Answer'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _card(
                    children: [
                      const Text(
                        'B) Join with an offer (paste Offer → get Answer)',
                      ),
                      const SizedBox(height: 8),
                      _monoField(
                        label: 'Paste Remote Offer here',
                        ctl: _offerInCtl,
                        maxLines: 10,
                      ),
                      const SizedBox(height: 6),
                      ElevatedButton(
                        onPressed: _acceptOfferGenerateAnswer,
                        child: const Text('Generate Answer'),
                      ),
                      const SizedBox(height: 6),
                      _monoField(
                        label: 'Your Answer (send back)',
                        ctl: _answerOutCtl,
                        maxLines: 10,
                        copy: true,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _card(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _todoCtl,
                        decoration: const InputDecoration(
                          labelText: 'Add a task',
                        ),
                        onSubmitted: (v) {
                          final t = v.trim();
                          if (t.isNotEmpty) {
                            _addTodo(t);
                            _todoCtl.clear();
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () {
                        final t = _todoCtl.text.trim();
                        if (t.isNotEmpty) {
                          _addTodo(t);
                          _todoCtl.clear();
                        }
                      },
                      child: const Text('Add'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ..._view.map((t) {
                  final ctl = TextEditingController(text: t.text);
                  return Card(
                    child: ListTile(
                      leading: Checkbox(
                        value: t.done,
                        onChanged: (v) {
                          if (v != null) _toggle(t, v);
                        },
                      ),
                      title: TextField(
                        controller: ctl,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                        ),
                        onSubmitted: (v) {
                          _editTodo(t, v.trim());
                        },
                      ),
                      subtitle: Text(
                        t.id,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white54,
                        ),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: () => _remove(t),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // Helper for styled card containers
  Widget _card({required List<Widget> children}) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFF1b1f2a),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFF2a3040)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    ),
  );

  // Helper for monospaced text fields (used for signaling messages)
  Widget _monoField({
    required String label,
    required TextEditingController ctl,
    int maxLines = 3,
    bool copy = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: Colors.white70),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: ctl,
          maxLines: maxLines,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        if (copy)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: ctl.text));
              },
              icon: const Icon(Icons.copy, size: 14),
              label: const Text('Copy'),
            ),
          ),
      ],
    );
  }
}
