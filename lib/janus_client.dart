import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/webrtc.dart';
import 'package:janus_client/Plugin.dart';
import 'package:janus_client/WebRTCHandle.dart';
import 'package:janus_client/utils.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class JanusClient {
  static const MethodChannel _channel = const MethodChannel('janus_client');
  List<String> servers;
  String apiSecret;
  String token;
  bool withCredentials;
  List<RTCIceServer> iceServers;
  int refreshInterval;
  bool _connected = false;
  int _sessionId;
  void Function() _onSuccess;
  void Function(dynamic) _onError;
  Uuid _uuid = Uuid();
  Map<String, dynamic> _transactions = {};
  Map<int, Plugin> _pluginHandles = {};

  dynamic get _apiMap =>
      withCredentials ? apiSecret != null ? {"apisecret": apiSecret} : {} : {};

  dynamic get _tokenMap =>
      withCredentials ? token != null ? {"token": token} : {} : {};
  IOWebSocketChannel _webSocketChannel;
  Stream<dynamic> _webSocketStream;
  WebSocketSink _webSocketSink;

  get isConnected => _connected;

  int get sessionId => _sessionId;

  JanusClient(
      {@required this.servers,
      @required this.iceServers,
      this.refreshInterval = 5,
      this.apiSecret,
      this.token,
      this.withCredentials = false});

  Future<dynamic> _attemptWebSocket(String url) async {
    String transaction = _uuid.v4().replaceAll('-', '');
    _webSocketChannel = IOWebSocketChannel.connect(url,
        protocols: ['janus-protocol'], pingInterval: Duration(seconds: 2));
    _webSocketSink = _webSocketChannel.sink;
    _webSocketStream = _webSocketChannel.stream.asBroadcastStream();

    _webSocketSink.add(stringify({
      "janus": "create",
      "transaction": transaction,
      ..._apiMap,
      ..._tokenMap
    }));

    var data = parse(await _webSocketStream.first);
    if (data["janus"] == "success") {
      _sessionId = data["data"]["id"];
      _connected = true;

      //to keep session alive otherwise session will die after default 60 seconds.
      _keepAlive(refreshInterval: refreshInterval);
      return data;
    }
  }
  Future<void> connect() async {
    if (servers is! List<String>) {
      debugPrint('invalid server format');
      return;
    }

    for (var serverUrl in servers) {
      if (serverUrl.startsWith('ws') || serverUrl.startsWith('wss')) {
        debugPrint('trying websocket interface');
        await _attemptWebSocket(serverUrl);

        if (isConnected) {
          break;
        }

        continue;
      }
    }
  }

  _keepAlive({int refreshInterval}) {
    // keep session live dude!
    Timer.periodic(Duration(seconds: refreshInterval), (timer) {
      _webSocketSink.add(stringify({
        "janus": "keepalive",
        "session_id": _sessionId,
        "transaction": _uuid.v4(),
        ..._apiMap,
        ..._tokenMap
      }));
    });
  }

  attach(Plugin plugin) async {
    if (_webSocketSink == null ||
        _webSocketStream == null ||
        _webSocketChannel == null) {
      return null;
    }

    var opaqueId = plugin.opaqueId;
    var transaction = _uuid.v4();
    Map<String, dynamic> request = {
      "janus": "attach",
      "plugin": plugin.plugin,
      "transaction": transaction
    };
    if (plugin.opaqueId != null) request["opaque_id"] = opaqueId;
    request["token"] = token;
    request["apisecret"] = apiSecret;
    request["session_id"] = sessionId;
    _webSocketSink.add(stringify(request));
    var data = parse(await _webSocketStream
        .firstWhere((element) => parse(element)["transaction"] == transaction));
    if (data["janus"] != "success") {
      plugin
          .onError("Ooops: " + data["error"].code + " " + data["error"].reason);
      return null;
    }
    print(data);
    int handleId = data["data"]["id"];
    debugPrint("Created handle: " + handleId.toString());

    _webSocketStream.listen((event) {
      _handleEvent(plugin, parse(event));
    });

    Map<String, dynamic> configuration = {
      "iceServers": iceServers.map((e) => e.toMap()).toList()
    };

    //print(configuration);
    RTCPeerConnection peerConnection =
        await createPeerConnection(configuration, {});
    WebRTCHandle webRTCHandle = WebRTCHandle(
      iceServers: iceServers,
    );
    webRTCHandle.pc = peerConnection;
    plugin.webRTCHandle = webRTCHandle;
    plugin.webSocketStream = _webSocketStream;
    plugin.webSocketSink = _webSocketSink;
    plugin.handleId = handleId;
    plugin.apiSecret = apiSecret;
    plugin.sessionId = _sessionId;
    plugin.token = token;
    plugin.pluginHandles = _pluginHandles;
    plugin.transactions = _transactions;
    if (plugin.onLocalStream != null) {
      plugin.onLocalStream(peerConnection.getLocalStreams());
    }
    peerConnection.onAddStream = (MediaStream stream) {
      if (plugin.onRemoteStream != null) {
        plugin.onRemoteStream(stream);
      }
    };

    // send trickle
    peerConnection.onIceCandidate = (RTCIceCandidate candidate) {
      debugPrint('sending trickle');
      Map<dynamic, dynamic> request = {
        "janus": "trickle",
        "candidate": candidate.toMap(),
        "transaction": "sendtrickle"
      };
      request["session_id"] = plugin.sessionId;
      request["handle_id"] = plugin.handleId;
      request["apisecret"] = plugin.apiSecret;
      request["token"] = plugin.token;
      plugin.webSocketSink.add(stringify(request));
    };

    _pluginHandles[handleId] = plugin;
    if (plugin.onSuccess != null) {
      plugin.onSuccess(plugin);
    }
  }

  _handleEvent(Plugin plugin, Map<String, dynamic> json) {
    print('handle event called');
    print(json);

    var eventName = json["janus"];
    switch (eventName) {
      case 'keepalive':
        {
          // Nothing happened
          debugPrint('Got a keepalive on session ' + sessionId.toString());
        }
        break;
      case 'ack':
        {
          // Just an ack, we can probably ignore
          debugPrint('Got an ack on session ' + sessionId.toString());
          debugPrint(json.toString());
          var transaction = json['transaction'];
          if (transaction != null) {
            var reportSuccess = _transactions[transaction];
            if (reportSuccess != null) reportSuccess(json);
//          delete transactions[transaction];
          }
        }
        break;
      case 'success':
        {
          // Success!
          debugPrint('Got a success on session ' + sessionId.toString());
          debugPrint(json.toString());
          var transaction = json['transaction'];
          if (transaction != null) {
            var reportSuccess = _transactions[transaction];
            if (reportSuccess != null) reportSuccess(json);
//          delete transactions[transaction];
          }
        }
        break;
      case 'trickle':
        {
          // We got a trickle candidate from Janus
          var sender = json['sender'];

          if (sender == null) {
            debugPrint('WMissing sender...');
            return;
          }
          var pluginHandle = _pluginHandles[sender];
          if (pluginHandle == null) {
            debugPrint('This handle is not attached to this session');
          }
          var candidate = json['candidate'];
          debugPrint(
              'Got a trickled candidate on session ' + sessionId.toString());
          debugPrint(candidate.toString());
          var config = pluginHandle.webRTCHandle;
          if (config.pc != null) {
            // Add candidate right now
            debugPrint('Adding remote candidate:' + candidate.toString());
            if (candidate.containsKey('sdpMid') &&
                candidate.containsKey('sdpMLineIndex')) {
              config.pc.addCandidate(RTCIceCandidate(candidate['candidate'],
                  candidate['sdpMid'], candidate['sdpMLineIndex']));
            }
          } else {
            // We didn't do setRemoteDescription (trickle got here before the offer?)
            debugPrint(
                'We didn\'t do setRemoteDescription (trickle got here before the offer?), caching candidate');
          }
        }
        break;
      case 'webrtcup':
        {
          // The PeerConnection with the server is up! Notify this
          debugPrint('Got a webrtcup event on session ' + sessionId.toString());
          debugPrint(json.toString());
          var sender = json['sender'];
          if (sender == null) {
            debugPrint('WMissing sender...');
          }
          var pluginHandle = _pluginHandles[sender];
          if (pluginHandle == null) {
            debugPrint('This handle is not attached to this session');
          }
          if (plugin.onWebRTCState != null) {
            plugin.onWebRTCState(true, null);
          }
        }
        break;
      case 'hangup':
        {
          // A plugin asked the core to hangup a PeerConnection on one of our handles
          debugPrint('Got a hangup event on session ' + sessionId.toString());
          debugPrint(json.toString());
          var sender = json['sender'];
          if (sender != null) {
            debugPrint('WMissing sender...');
          }
          var pluginHandle = _pluginHandles[sender];
          if (pluginHandle == null) {
            debugPrint('This handle is not attached to this session');
          } else {
            if (plugin.onWebRTCState != null) {
              pluginHandle.onWebRTCState(false, json['reason']);
            }
//      pluginHandle.hangup();
            if (plugin.onDestroy != null) {
              pluginHandle.onDestroy();
            }
            _pluginHandles.remove(sender);
          }
        }
        break;
      case 'detached':
        {
          // A plugin asked the core to detach one of our handles
          debugPrint('Got a detached event on session ' + sessionId.toString());
          debugPrint(json.toString());
          var sender = json['sender'];
          if (sender == null) {
            debugPrint('WMissing sender...');
          }
          var pluginHandle = _pluginHandles[sender];
          if (pluginHandle == null) {
            // Don't warn here because destroyHandle causes this situation.
          }
          plugin.onDetached();
          pluginHandle.detach();
        }
        break;
      case 'media':
        {
          // Media started/stopped flowing
          debugPrint('Got a media event on session ' + sessionId.toString());
          debugPrint(json.toString());
          var sender = json['sender'];
          if (sender == null) {
            debugPrint('WMissing sender...');
          }
          var pluginHandle = _pluginHandles[sender];
          if (pluginHandle == null) {
            debugPrint('This handle is not attached to this session');
          }
          if (plugin.onMediaState != null) {
            plugin.onMediaState(json['type'], json['receiving']);
          }
        }
        break;
      case 'slowlink':
        {
          debugPrint('Got a slowlink event on session ' + sessionId.toString());
          debugPrint(json.toString());
          // Trouble uplink or downlink
          var sender = json['sender'];
          if (sender == null) {
            debugPrint('WMissing sender...');
          }
          var pluginHandle = _pluginHandles[sender];
          if (pluginHandle == null) {
            debugPrint('This handle is not attached to this session');
          }
          pluginHandle.slowLink(json['uplink'], json['lost']);
        }
        break;
      case 'error':
        {
          // Oops, something wrong happened
          debugPrint('EOoops: ' +
              json['error']['code'] +
              ' ' +
              json['error']['reason']); // FIXME
          var transaction = json['transaction'];
          if (transaction) {
            var reportSuccess = _transactions[transaction];
            if (reportSuccess) {
              reportSuccess(json);
            }
          }
        }
        break;
      case 'event':
        {
          debugPrint('Got a plugin event on session ' + sessionId.toString());
          debugPrint(json.toString());
          var sender = json['sender'];
          if (sender == null) {
            debugPrint('WMissing sender...');
            return;
          }
          var plugindata = json['plugindata'];
          if (plugindata == null) {
            debugPrint('WMissing plugindata...');
            return;
          }
          debugPrint('  -- Event is coming from ' +
              sender.toString() +
              ' (' +
              plugindata['plugin'].toString() +
              ')');
          var data = plugindata['data'];
//      debugPrint(data.toString());
          var pluginHandle = _pluginHandles[sender];
          if (pluginHandle == null) {
            debugPrint('WThis handle is not attached to this session');
          }
          var jsep = json['jsep'];
          if (jsep != null) {
            debugPrint('Handling SDP as well...');
            debugPrint(jsep.toString());
          }
          var callback = pluginHandle.onMessage;
          if (callback != null) {
            debugPrint('Notifying application...');
            // Send to callback specified when attaching plugin handle
            callback(data, jsep);
          } else {
            // Send to generic callback (?)
            debugPrint('No provided notification callback');
          }
        }
        break;
      case 'timeout':
        {
          debugPrint('ETimeout on session ' + sessionId.toString());
          debugPrint(json.toString());
          if (_webSocketChannel != null) {
            _webSocketChannel.sink.close(3504, 'Gateway timeout');
          }
        }
        break;
      default:
        {
          var sessionId = _sessionId.toString();
          debugPrint("Unknown message/event  '$eventName' on session  $sessionId");
          debugPrint(json.toString());
        }
        break;
    }
  }
}
