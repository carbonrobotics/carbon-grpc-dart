// Copyright (c) 2026, the gRPC project authors. Please see the AUTHORS file
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

import 'dart:async';

import 'package:grpc/src/client/transport/http2_transport.dart';
import 'package:grpc/src/shared/message.dart';
import 'package:http2/transport.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';

import '../src/client_utils.mocks.dart';

void main() {
  const grace = Duration(milliseconds: 20);
  const pastGrace = Duration(milliseconds: 60);

  late MockClientTransportStream stream;
  late StreamController<StreamMessage> toClient;
  late StreamController<StreamMessage> fromClient;
  late Http2TransportStream transport;

  final responseHeaders = [
    Header.ascii(':status', '200'),
    Header.ascii('content-type', 'application/grpc'),
  ];
  var headersSent = false;

  setUp(() {
    headersSent = false;
    stream = MockClientTransportStream();
    toClient = StreamController();
    fromClient = StreamController();
    when(stream.incomingMessages).thenAnswer((_) => toClient.stream);
    when(stream.outgoingMessages).thenReturn(fromClient.sink);
    when(stream.terminate()).thenReturn(null);
    transport = Http2TransportStream(
      stream,
      (error, _) => fail('Unexpected error: $error'),
      null,
      null,
      resetGrace: grace,
    );
  });

  tearDown(() {
    toClient.close();
    fromClient.close();
  });

  void sendHeaders() {
    headersSent = true;
    toClient.add(HeadersStreamMessage(responseHeaders));
  }

  /// The server ends the stream with its trailers (trailers-only if no
  /// headers were sent, which the decoder requires to carry `:status`).
  void serverEndsStream() {
    toClient.add(
      HeadersStreamMessage([
        if (!headersSent) ...responseHeaders,
        Header.ascii('grpc-status', '0'),
      ], endStream: true),
    );
    toClient.close();
  }

  test('terminate closes the request side without resetting', () async {
    final requestClosed = Completer<void>();
    fromClient.stream.listen(null, onDone: requestClosed.complete);

    await transport.terminate();

    await requestClosed.future;
    verifyNever(stream.terminate());
  });

  test('terminate leaves the stream for the server to end', () async {
    final received = <GrpcMessage>[];
    transport.incomingMessages.listen(received.add);
    sendHeaders();
    await Future.delayed(Duration.zero);
    expect(received, hasLength(1));

    await transport.terminate();
    serverEndsStream();
    await Future.delayed(pastGrace);

    verifyNever(stream.terminate());
    expect(received, hasLength(1), reason: 'frames are dropped while draining');
    expect(transport.done, completes);
  });

  test('terminate resets a stream the server never ends', () async {
    await transport.terminate();
    await Future.delayed(pastGrace);

    verify(stream.terminate()).called(1);
  });

  test('terminate drains while the caller is paused', () async {
    final subscription = transport.incomingMessages.listen(null)..pause();

    await transport.terminate();
    serverEndsStream();
    await Future.delayed(pastGrace);

    verifyNever(stream.terminate());
    expect(transport.done, completes);
    await subscription.cancel();
  });

  test('terminate drains without a listener', () async {
    await transport.terminate();
    serverEndsStream();
    await Future.delayed(pastGrace);

    verifyNever(stream.terminate());
    expect(transport.done, completes);
  });

  test('terminate after the server ended the stream does nothing', () async {
    transport.incomingMessages.listen(null);
    sendHeaders();
    serverEndsStream();
    await transport.done;

    await transport.terminate();
    await Future.delayed(pastGrace);

    verifyNever(stream.terminate());
  });

  test('terminate is idempotent', () async {
    await transport.terminate();
    await transport.terminate();
    await Future.delayed(pastGrace);

    verify(stream.terminate()).called(1);
  });

  test('reset skips the remaining grace', () async {
    await transport.terminate();
    transport.reset();
    verify(stream.terminate()).called(1);

    await Future.delayed(pastGrace);
    verifyNever(stream.terminate());
  });

  test('pausing the caller pauses the server stream', () async {
    final subscription = transport.incomingMessages.listen(null);
    await Future.delayed(Duration.zero);
    expect(toClient.isPaused, isFalse);

    subscription.pause();
    await Future.delayed(Duration.zero);
    expect(toClient.isPaused, isTrue);

    subscription.resume();
    await Future.delayed(Duration.zero);
    expect(toClient.isPaused, isFalse);
    await subscription.cancel();
  });

  group('cancel', () {
    // A reset grace long enough that only the cancel grace can fire in time.
    const longGrace = Duration(seconds: 10);

    setUp(() {
      transport = Http2TransportStream(
        stream,
        (error, _) => fail('Unexpected error: $error'),
        null,
        null,
        resetGrace: longGrace,
        cancelGrace: grace,
      );
    });

    test('resets after the cancel grace', () async {
      await transport.cancel();
      verifyNever(stream.terminate());

      await Future.delayed(pastGrace);
      verify(stream.terminate()).called(1);
    });

    test('leaves the stream for the server to end within the grace', () async {
      await transport.cancel();
      serverEndsStream();
      await Future.delayed(pastGrace);

      verifyNever(stream.terminate());
      expect(transport.done, completes);
    });

    test('after terminate keeps the reset grace', () async {
      // The response stream's done event cancels the call after every
      // termination, so a later cancel must not shorten a deadline's grace.
      await transport.terminate();
      await transport.cancel();
      await Future.delayed(pastGrace);

      verifyNever(stream.terminate());
      transport.reset();
    });

    test('before terminate keeps the cancel grace', () async {
      await transport.cancel();
      await transport.terminate();
      await Future.delayed(pastGrace);

      verify(stream.terminate()).called(1);
    });
  });

  test('a zero grace resets synchronously', () {
    transport = Http2TransportStream(
      stream,
      (error, _) => fail('Unexpected error: $error'),
      null,
      null,
      resetGrace: Duration.zero,
    );

    transport.terminate();
    verify(stream.terminate()).called(1);
  });

  test('a reset drops request frames not yet handed to the stream', () async {
    transport = Http2TransportStream(
      stream,
      (error, _) => fail('Unexpected error: $error'),
      null,
      null,
      resetGrace: Duration.zero,
    );
    // package:http2 closes its sink when the stream is reset.
    when(stream.terminate()).thenAnswer((_) => fromClient.close());
    final sent = <StreamMessage>[];
    fromClient.stream.listen(sent.add);

    transport.outgoingMessages.add([1, 2, 3]);
    await transport.terminate();
    await Future.delayed(Duration.zero);

    expect(sent, isEmpty);
  });

  test('an undecodable response resets the stream', () async {
    final errors = <Object>[];
    transport.incomingMessages.listen(null, onError: errors.add);
    sendHeaders();
    // A compressed frame with no grpc-encoding to decompress it.
    toClient.add(DataStreamMessage([1, 0, 0, 0, 1, 0]));
    await Future.delayed(Duration.zero);

    expect(errors, hasLength(1));
    verify(stream.terminate()).called(1);
    expect(transport.done, completes);
  });
}
