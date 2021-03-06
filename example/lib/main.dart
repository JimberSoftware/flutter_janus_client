import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/webrtc.dart';
import 'package:janus_client/Plugin.dart';
import 'package:janus_client/janus_client.dart';
import 'package:janus_client/utils.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatefulWidget {
  @override
  _MyAppState createState() => _MyAppState();
}


final String janusServer = 'wss://janus-wss.staging.jimber.org/janus';
final _localRenderer = new RTCVideoRenderer();
final _remoteRenderer = new RTCVideoRenderer();

class _MyAppState extends State<MyApp> {
  JanusClient janusClient;
  Plugin pluginHandle;
  Plugin subscriberHandle;
  MediaStream remoteStream;
  MediaStream myStream;

  @override
  void didChangeDependencies() async {
    // TODO: implement didChangeDependencies
    super.didChangeDependencies();
  }

  @override
  void initState() {
    super.initState();
    initRenderers();
  }

  initRenderers() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
  }

  _newRemoteFeed(JanusClient j, feed) async {
    print('remote plugin attached');
    j.attach(Plugin(
        plugin: 'janus.plugin.videoroom',
        onMessage: (msg, jsep) async {
          if (jsep != null) {
            await subscriberHandle.handleRemoteJsep(jsep);
            var body = {"request": "start", "room": 1234};

            await subscriberHandle.send(
                message: body,
                jsep: await subscriberHandle.createAnswer(),
                onSuccess: () {});
          }
        },
        onSuccess: (plugin) {
          setState(() {
            subscriberHandle = plugin;
          });
          var register = {
            "request": "join",
            "room": 1234,
            "ptype": "subscriber",
            "feed": feed,
//            "private_id": 12535
          };
          subscriberHandle.send(message: register, onSuccess: () async {});
        },
        onRemoteStream: (stream) {
          print('got remote stream');
          setState(() {
            remoteStream = stream;
            _remoteRenderer.srcObject = remoteStream;
            _remoteRenderer.mirror = true;
          });
        }));
  }

  Future<void> initPlatformState() async {
    setState(() async {
      janusClient = JanusClient(servers: [
        janusServer
      ], iceServers: [
        RTCIceServer(url: "stun:stun.l.google.com:19302",credential: 'no cred', username: 'test'),
      ]);
      try {

        await janusClient.connect();
        debugPrint('voilla! connection established');
        Map<String, dynamic> configuration = {
          "iceServers": janusClient.iceServers.map((e) => e.toMap()).toList()
        };

        janusClient.attach(Plugin(
            plugin: 'janus.plugin.videoroom',
            onMessage: (msg, jsep) async {
              print('publisheronmsg');
              if (msg["publishers"] != null) {
                var list = msg["publishers"];
                print('got publihers');
                print(list);
                _newRemoteFeed(janusClient, list[0]["id"]);
              }

              if (jsep != null) {
                pluginHandle.handleRemoteJsep(jsep);
              }
            },
            onSuccess: (plugin) async {
              setState(() {
                pluginHandle = plugin;
              });
              MediaStream stream = await plugin.initializeMediaDevices();
              setState(() {
                myStream = stream;
              });
              setState(() {
                _localRenderer.srcObject = myStream;
                _localRenderer.mirror = true;
              });
              var register = {
                "request": "join",
                "room": 1234,
                "ptype": "publisher",
                "display": 'shivansh'
              };
              plugin.send(
                  message: register,
                  onSuccess: () async {
                    var publish = {
                      "request": "configure",
                      "audio": true,
                      "video": true,
                      "bitrate": 2000000
                    };
                    RTCSessionDescription offer = await plugin.createOffer();
                    plugin.send(message: publish, jsep: offer, onSuccess: () {});
                  });
            }));
      } catch (e){
        print(e);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          actions: [
            IconButton(
                icon: Icon(
                  Icons.call,
                  color: Colors.greenAccent,
                ),
                onPressed: () async {
                  await this.initRenderers();
                  await this.initPlatformState();
//                  -_localRenderer.
                }),
            IconButton(
                icon: Icon(
                  Icons.call_end,
                  color: Colors.red,
                ),
                onPressed: () {
                  pluginHandle.hangup();
                  subscriberHandle.hangup();
                  _localRenderer.srcObject = null;
                  _localRenderer.dispose();
                  _remoteRenderer.srcObject = null;
                  _remoteRenderer.dispose();
                  setState(() {
                    pluginHandle = null;
                    subscriberHandle = null;
                  });
                }),
            IconButton(
                icon: Icon(
                  Icons.switch_camera,
                  color: Colors.white,
                ),
                onPressed: () {
                  if (pluginHandle != null) {
                    pluginHandle.switchCamera();
                  }
                })
          ],
          title: const Text('janus_client'),
        ),
        body: Stack(children: [
          Positioned.fill(
            child: RTCVideoView(
              _remoteRenderer,
            ),
          ),
          Align(
            child: Container(
              child: RTCVideoView(
                _localRenderer,
              ),
              height: 200,
              width: 200,
            ),
            alignment: Alignment.bottomRight,
          )
        ]),
      ),
    );
  }
}
