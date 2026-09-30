// Copyright (c) 2017, the gRPC project authors. Please see the AUTHORS file
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

import 'package:grpc/grpc.dart';
import 'package:http2/transport.dart';
import 'package:mockito/mockito.dart';
import 'package:test/test.dart';

import 'src/client_utils.dart';
import 'src/server_utils.dart';
import 'src/utils.dart';

void main() {
  const dummyValue = 0;

  group('Unit:', () {
    test('Timeouts are converted correctly to header string', () {
      expect(toTimeoutString(Duration(microseconds: -1)), '1n');
      expect(toTimeoutString(Duration(microseconds: 0)), '0u');
      expect(toTimeoutString(Duration(microseconds: 107)), '107u');
      expect(toTimeoutString(Duration(hours: 2, microseconds: 17)), '7200S');
      expect(toTimeoutString(Duration(milliseconds: 1420665)), '1420S');
      expect(toTimeoutString(Duration(seconds: 2, microseconds: 3)), '2000m');
      expect(toTimeoutString(Duration(seconds: 2, milliseconds: 3)), '2003m');
      expect(toTimeoutString(Duration(hours: 17, seconds: 3)), '61203S');
      expect(toTimeoutString(Duration(minutes: 42)), '2520S');
      expect(toTimeoutString(Duration(days: 201)), '4824H');
    });

    test('Timeouts are converted correctly from header string', () {
      expect(fromTimeoutString(null), isNull);
      expect(fromTimeoutString('1n'), Duration(microseconds: 1000));
      expect(fromTimeoutString('0u'), Duration(microseconds: 0));
      expect(fromTimeoutString('107u'), Duration(microseconds: 107));
      expect(fromTimeoutString('7200S'), Duration(hours: 2));
      expect(fromTimeoutString('1420S'), Duration(seconds: 1420));
      expect(fromTimeoutString('2000m'), Duration(seconds: 2));
      expect(fromTimeoutString('2003m'), Duration(milliseconds: 2003));
      expect(fromTimeoutString('17H'), Duration(hours: 17));
      expect(fromTimeoutString('157M'), Duration(minutes: 157));
      expect(fromTimeoutString('1'), isNull);
      expect(fromTimeoutString('202'), isNull);
      expect(fromTimeoutString('1s'), isNull);
      expect(fromTimeoutString('ab'), isNull);
      expect(fromTimeoutString('-1S'), Duration(seconds: -1));
    });
  });

  group('Client:', () {
    late ClientHarness harness;

    setUp(() {
      harness = ClientHarness()..setUp();
    });

    tearDown(() {
      harness.tearDown();
    });

    test('Calls time out if deadline is exceeded', () async {
      void handleRequest(StreamMessage message) {
        validateDataMessage(message);
        final delay = Future.delayed(Duration(milliseconds: 2));
        expect(delay, completes);
        delay.then((_) {
          try {
            harness
              ..sendResponseHeader()
              ..sendResponseValue(dummyValue)
              ..sendResponseTrailer();
          } catch (error) {
            expect(error, isStateError);
          }
        });
      }

      final timeout = Duration(microseconds: 1);
      await harness.runFailureTest(
        clientCall: harness.client.unary(
          dummyValue,
          options: CallOptions(timeout: timeout),
        ),
        expectedException: GrpcError.deadlineExceeded('Deadline exceeded'),
        expectedPath: '/Test/Unary',
        expectedTimeout: timeout,
        serverHandlers: [handleRequest],
      );
    });

    group('past their deadline', () {
      const grace = Duration(milliseconds: 20);
      const pastGrace = Duration(milliseconds: 60);
      final timeout = Duration(microseconds: 1);

      setUp(() {
        harness.channelOptions.resetStreamGrace = grace;
      });

      test('leave the stream for the server to end', () async {
        final serverDone = Completer<void>();
        void handleRequest(StreamMessage message) {
          validateDataMessage(message);
          // The reply is already in flight when the client's timer fires.
          Future.delayed(Duration(milliseconds: 5), () {
            harness
              ..sendResponseHeader()
              ..sendResponseTrailer();
            serverDone.complete();
          });
        }

        await harness.runFailureTest(
          clientCall: harness.client.unary(
            dummyValue,
            options: CallOptions(timeout: timeout),
          ),
          expectedException: GrpcError.deadlineExceeded('Deadline exceeded'),
          expectedPath: '/Test/Unary',
          expectedTimeout: timeout,
          serverHandlers: [handleRequest],
        );
        await serverDone.future;
        await Future.delayed(pastGrace);
        verifyNever(harness.stream.terminate());
      });

      test('reset a stream the server never ends', () async {
        await harness.runFailureTest(
          clientCall: harness.client.unary(
            dummyValue,
            options: CallOptions(timeout: timeout),
          ),
          expectedException: GrpcError.deadlineExceeded('Deadline exceeded'),
          expectedPath: '/Test/Unary',
          expectedTimeout: timeout,
          serverHandlers: [validateDataMessage],
        );
        verifyNever(harness.stream.terminate());
        await Future.delayed(pastGrace);
        verify(harness.stream.terminate()).called(1);
      });

      test('drain while the caller is paused', () async {
        final requestDone = Completer<void>();
        harness.fromClient.stream.listen(
          validateDataMessage,
          onDone: requestDone.complete,
        );

        final errors = <Object>[];
        final subscription =
            harness.client
                .serverStreaming(
                  dummyValue,
                  options: CallOptions(timeout: timeout),
                )
                .listen(
                  (_) => fail('Unexpected response'),
                  onError: errors.add,
                  cancelOnError: true,
                )
              ..pause();
        await requestDone.future;
        harness
          ..sendResponseHeader()
          ..sendResponseTrailer();
        await Future.delayed(pastGrace);
        verifyNever(harness.stream.terminate());

        subscription.resume();
        await Future.delayed(Duration.zero);
        expect(errors, [GrpcError.deadlineExceeded('Deadline exceeded')]);
        await subscription.cancel();
      });

      test('are reset when the connection shuts down', () async {
        await harness.runFailureTest(
          clientCall: harness.client.unary(
            dummyValue,
            options: CallOptions(timeout: timeout),
          ),
          expectedException: GrpcError.deadlineExceeded('Deadline exceeded'),
          expectedPath: '/Test/Unary',
          expectedTimeout: timeout,
          serverHandlers: [validateDataMessage],
        );
        verifyNever(harness.stream.terminate());
        await harness.connection!.shutdown();
        verify(harness.stream.terminate()).called(1);
        await Future.delayed(pastGrace);
        verifyNever(harness.stream.terminate());
      });

      test('before the request is sent do not open a stream', () async {
        final provider = Completer<void>();
        final call = harness.client.unary(
          dummyValue,
          options: CallOptions(
            timeout: timeout,
            providers: [(metadata, uri) => provider.future],
          ),
        );
        await harness.expectThrows(
          call,
          GrpcError.deadlineExceeded('Deadline exceeded'),
        );
        provider.complete();
        await Future.delayed(Duration.zero);
        verifyNever(
          harness.transport.makeRequest(any, endStream: anyNamed('endStream')),
        );
      });

      test('before the request is sent cancel the request stream', () async {
        final provider = Completer<void>();
        final requests = StreamController<int>();
        final call = harness.client.clientStreaming(
          requests.stream,
          options: CallOptions(
            timeout: timeout,
            providers: [(metadata, uri) => provider.future],
          ),
        );
        await harness.expectThrows(
          call,
          GrpcError.deadlineExceeded('Deadline exceeded'),
        );
        provider.complete();
        await expectLater(requests.done, completes);
      });
    });
  });

  group('Server:', () {
    late ServerHarness harness;

    setUp(() {
      harness = ServerHarness()..setUp();
    });

    tearDown(() {
      harness.tearDown();
    });

    test('Calls time out if deadline is exceeded', () async {
      final handlerFinished = Completer<void>();
      Future<int> methodHandler(ServiceCall call, Future<int> request) async {
        try {
          expect(call.isTimedOut, isFalse);
          await Future.delayed(Duration(milliseconds: 50));
          expect(call.isTimedOut, isTrue);
          try {
            await request;
          } catch (error) {
            expect(error, GrpcError.deadlineExceeded('Deadline exceeded'));
            return dummyValue;
          }
          fail('Did not throw');
        } catch (error, stack) {
          registerException(error, stack);
        } finally {
          handlerFinished.complete();
        }
        return dummyValue;
      }

      harness
        ..service.unaryHandler = methodHandler
        ..expectErrorResponse(StatusCode.deadlineExceeded, 'Deadline exceeded')
        ..sendRequestHeader('/Test/Unary', timeout: Duration(microseconds: 1));
      await Future.wait([handlerFinished.future, harness.fromServer.done]);
    });
  }, testOn: 'vm');
}
