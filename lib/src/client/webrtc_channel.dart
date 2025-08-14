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

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'call.dart';
import 'channel.dart';
import 'connection.dart';
import 'http2_connection.dart';
import 'options.dart';
import 'webrtc_transport_connector.dart';
import 'method.dart';
import '../shared/status.dart';

/// A gRPC client channel that uses WebRTC DataChannel as the underlying
/// transport for HTTP/2 connections.
/// 
/// This channel leverages the existing HTTP/2 infrastructure in the gRPC
/// library but routes all communication through a WebRTC DataChannel instead
/// of a TCP socket. This enables peer-to-peer gRPC communication or tunneling
/// gRPC over WebRTC connections while maintaining full HTTP/2 compatibility.
/// 
/// Example usage:
/// ```dart
/// // Assume you have a WebRTC DataChannel set up
/// final dataChannel = ...;
/// 
/// final channel = ClientChannel(
///   dataChannel,
///   authority: 'peer-service-name',
///   options: ChannelOptions(),
/// );
/// 
/// final client = MyServiceClient(channel);
/// final response = await client.myMethod(request);
/// ```
/// 
/// ## Important Requirements
/// 
/// 1. **Ordered Delivery**: The WebRTC DataChannel must be configured with
///    `ordered: true` to ensure HTTP/2 frames arrive in the correct order.
/// 
/// 2. **Reliable Transport**: Use reliable delivery mode (no packet loss)
///    as HTTP/2 expects a reliable transport layer.
/// 
/// 3. **Binary Data**: The DataChannel must support binary data transmission.
/// 
/// 4. **Open State**: The DataChannel should be in the 'open' state before
///    creating the channel.
/// 
/// ## Benefits over Raw WebRTC Transport
/// 
/// - Full HTTP/2 multiplexing support
/// - Proper gRPC metadata handling
/// - Stream flow control
/// - Built-in compression support
/// - Compatibility with all gRPC features
class ClientChannel extends ClientChannelBase {
  final RTCDataChannel _dataChannel;
  final String _authority;
  final ChannelOptions _options;

  /// Creates a new HTTP/2 over WebRTC client channel.
  /// 
  /// [dataChannel] - The pre-established WebRTC DataChannel to use for transport
  /// [authority] - The authority (service name) for the gRPC service
  /// [options] - Channel options for configuration
  /// [channelShutdownHandler] - Optional callback when channel shuts down
  ClientChannel(
    this._dataChannel, {
    required String authority,
    ChannelOptions options = const ChannelOptions(),
    super.channelShutdownHandler,
  })  : _authority = authority,
        _options = options;

  @override
  ClientConnection createConnection() {
    // Create a WebRTC transport connector
    final transportConnector = WebRTCTransportConnector(_dataChannel, _authority);
    
    // Use the existing HTTP/2 connection implementation with our WebRTC transport
    return Http2ClientConnection.fromClientTransportConnector(
      transportConnector,
      _options,
    );
  }

  @override
  ClientCall<Q, R> createCall<Q, R>(
      ClientMethod<Q, R> method, Stream<Q> requests, CallOptions options) {
    if (_dataChannel.state != RTCDataChannelState.RTCDataChannelOpen) {
      throw GrpcError.unavailable('DataChannel is not open');
    }
    return super.createCall(method, requests, options);
  }
}
