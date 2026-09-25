// Copyright (c) 2024, the gRPC project authors. Please see the AUTHORS file
// for details. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Needs flutter_webrtc, which this package does not depend on, so it cannot run
// under `dart test` here. Run it through a consumer that resolves both, e.g.
// from the Operator app: `fvm flutter test ../carbon-grpc-dart/test/client_tests/webrtc_transport_connector_test.dart`.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:grpc/src/client/webrtc_transport_connector.dart';
import 'package:http2/transport.dart';
import 'package:test/test.dart';

/// In-memory data channel that records what the connector sends.
class FakeDataChannel extends RTCDataChannel {
  RTCDataChannelState _state = RTCDataChannelState.RTCDataChannelOpen;
  final sent = <List<int>>[];

  @override
  RTCDataChannelState? get state => _state;

  @override
  int? get id => 1;

  @override
  String? get label => 'data';

  @override
  int? get bufferedAmount => 0;

  @override
  Future<int> getBufferedAmount() async => 0;

  @override
  Future<void> send(RTCDataChannelMessage message) async {
    sent.add(message.binary);
  }

  @override
  Future<void> close() async {
    if (_state == RTCDataChannelState.RTCDataChannelClosed) return;
    _state = RTCDataChannelState.RTCDataChannelClosed;
    onDataChannelState?.call(_state);
  }

  /// Number of HTTP/2 client prefaces sent on this channel.
  int get prefaceCount => sent
      .where(
        (m) =>
            latin1.decode(m, allowInvalid: true).startsWith('PRI * HTTP/2.0'),
      )
      .length;
}

Future<void> _flush() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  late FakeDataChannel channel;
  late WebRTCTransportConnector connector;

  setUp(() {
    channel = FakeDataChannel();
    connector = WebRTCTransportConnector(channel, 'test');
  });

  test('first connect sends one preface', () async {
    await connector.connect();
    await _flush();
    expect(channel.prefaceCount, 1);
  });

  test(
    'second connect fails, closes the channel, and sends no second preface',
    () async {
      await connector.connect();
      await _flush();
      final handler = channel.onMessage;

      await expectLater(connector.connect(), throwsStateError);
      await _flush();

      expect(channel.prefaceCount, 1);
      expect(channel.onMessage, same(handler));
      expect(channel.state, RTCDataChannelState.RTCDataChannelClosed);
      await connector.done.timeout(const Duration(seconds: 1));
    },
  );

  test(
    'connect on a channel that is not open fails and can be retried',
    () async {
      channel._state = RTCDataChannelState.RTCDataChannelConnecting;
      await expectLater(connector.connect(), throwsStateError);

      channel._state = RTCDataChannelState.RTCDataChannelOpen;
      await connector.connect();
      await _flush();
      expect(channel.prefaceCount, 1);
    },
  );

  test(
    'channel close ends in-flight streams instead of leaving them hung',
    () async {
      final transport = await connector.connect();
      final stream = transport.makeRequest([Header.ascii(':method', 'POST')]);
      final ended = Completer<void>();
      stream.incomingMessages.listen(
        (_) {},
        onError: (_) {
          if (!ended.isCompleted) ended.complete();
        },
        onDone: () {
          if (!ended.isCompleted) ended.complete();
        },
      );
      await _flush();

      await channel.close();

      await ended.future.timeout(const Duration(seconds: 1));
    },
  );
}
