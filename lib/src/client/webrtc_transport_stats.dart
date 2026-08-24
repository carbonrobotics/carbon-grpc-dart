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

/// Counters describing how the WebRTC data-channel transport is behaving.
///
/// These exist to tell the native and web data-channel implementations apart at
/// runtime. `flutter_webrtc`'s native `RTCDataChannel.bufferedAmount` is a cache
/// refreshed by an asynchronous platform event, while the web implementation
/// reads the live JS property; [bufferedAmountDivergenceMax] measures that gap.
/// Native `send()` also cannot report failure, so [sendErrors] stays zero on iOS
/// even when libwebrtc refuses a buffer — [queuedBytesDroppedOnClose] is the
/// symptom that shows up instead.
///
/// Deliberately plain integer counters: this is on the hot path for every
/// HTTP/2 frame, and anything more expensive would perturb the main-thread
/// congestion being measured.
class WebRTCTransportStats {
  /// Messages handed to `RTCDataChannel.send`.
  int sends = 0;

  /// Bytes handed to `RTCDataChannel.send`.
  int bytesSent = 0;

  /// Messages delivered by `RTCDataChannel.onMessage`.
  int messagesReceived = 0;

  /// Bytes delivered by `RTCDataChannel.onMessage`.
  int bytesReceived = 0;

  /// Deepest the outgoing queue ever got. A large value means the sink is
  /// absorbing more than the channel can drain.
  int queueDepthMax = 0;

  /// Times the pump blocked because the channel was above the high-water mark.
  int drainWaits = 0;

  /// Times the drain wait ended on the poll fallback rather than on
  /// `onBufferedAmountLow`. High on native means the buffered-amount event
  /// stream is lagging behind the platform thread.
  int drainPollFallbacks = 0;

  /// Times `send()` threw. Expected to stay 0 on iOS/macOS even under failure,
  /// because the plugin discards `sendData:`'s return value.
  int sendErrors = 0;

  /// Bytes still queued when the channel went away — data the peer never got.
  int queuedBytesDroppedOnClose = 0;

  /// Time from the transport connecting to the first inbound message.
  ///
  /// Stays null if the peer never delivered anything — the signature of an
  /// HTTP/2 preface lost in the channel-open window.
  Duration? timeToFirstMessage;

  /// Number of times the cached and live buffered amounts were compared.
  int bufferedAmountSamples = 0;

  /// Largest observed `live - cached` buffered-amount gap, in bytes. Stays 0 on
  /// web; a large value on native is the backpressure blind spot.
  int bufferedAmountDivergenceMax = 0;

  /// Largest live buffered amount seen. Approaching libwebrtc's ~16 MiB cap
  /// means sends are about to start failing silently.
  int liveBufferedAmountMax = 0;

  void recordSend(int bytes) {
    sends++;
    bytesSent += bytes;
  }

  void recordReceive(int bytes) {
    messagesReceived++;
    bytesReceived += bytes;
  }

  void recordQueueDepth(int depth) {
    if (depth > queueDepthMax) queueDepthMax = depth;
  }

  void recordBufferedAmounts({required int cached, required int live}) {
    bufferedAmountSamples++;
    final divergence = live - cached;
    if (divergence > bufferedAmountDivergenceMax) {
      bufferedAmountDivergenceMax = divergence;
    }
    if (live > liveBufferedAmountMax) liveBufferedAmountMax = live;
  }

  @override
  String toString() =>
      'WebRTCTransportStats(sends: $sends, bytesSent: $bytesSent, '
      'received: $messagesReceived/$bytesReceived B, '
      'timeToFirstMessage: $timeToFirstMessage, '
      'queueDepthMax: $queueDepthMax, drainWaits: $drainWaits, '
      'drainPollFallbacks: $drainPollFallbacks, sendErrors: $sendErrors, '
      'queuedBytesDroppedOnClose: $queuedBytesDroppedOnClose, '
      'bufferedAmountSamples: $bufferedAmountSamples, '
      'bufferedAmountDivergenceMax: $bufferedAmountDivergenceMax, '
      'liveBufferedAmountMax: $liveBufferedAmountMax)';
}
