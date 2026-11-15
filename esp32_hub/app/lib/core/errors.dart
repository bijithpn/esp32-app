import 'dart:async';

import 'bridge.dart';

/// What went wrong when talking to a board. The UI maps this to plain language; the raw text only goes to diagnostics.
enum HubError { timeout, unreachable, refused, auth, rateLimited, badResponse, deviceError, wrongDevice, noNetwork, stale, cancelled, unknown }

class HubException implements Exception {
  HubException(this.kind, [this.detail = '', this.code = '']);
  final HubError kind;
  final String detail;

  /// The board's own error code (errorCode field), when it sent one.
  final String code;

  @override
  String toString() => 'HubException(${kind.name}${code.isEmpty ? '' : ', $code'}${detail.isEmpty ? '' : ': $detail'})';
}

HubException toHubException(Object e) {
  if (e is HubException) return e;
  if (e is HubNetError) {
    switch (e.kind) {
      case 'timeout':
        return HubException(HubError.timeout, e.message);
      case 'refused':
        return HubException(HubError.refused, e.message);
      case 'unreachable':
      case 'dns':
        return HubException(HubError.unreachable, e.message);
      default:
        return HubException(HubError.unreachable, e.message);
    }
  }
  if (e is TimeoutException) return HubException(HubError.timeout);
  return HubException(HubError.unknown, '$e');
}

/// Plain-language text for the main UI. Technical detail stays in diagnostics.
String friendlyError(Object e) {
  final h = toHubException(e);
  switch (h.kind) {
    case HubError.timeout:
    case HubError.unreachable:
    case HubError.refused:
      return 'Your Hub isn\'t responding. Check that it\'s powered on and connected to Wi-Fi.';
    case HubError.auth:
      return 'The Hub is locked and didn\'t accept this phone\'s token. Re-pair it or enter the token again.';
    case HubError.rateLimited:
      return 'The Hub paused requests after several wrong tokens. Try again in about 30 seconds.';
    case HubError.wrongDevice:
      return 'A different device answered at that address. Searching for your Hub again.';
    case HubError.noNetwork:
      return 'Your phone isn\'t on a Wi-Fi network. Join the same network as the Hub.';
    case HubError.stale:
      return 'That action took too long to send, so it was skipped.';
    case HubError.cancelled:
      return 'Cancelled.';
    case HubError.deviceError:
      return h.code == 'unknown_scene' ? 'This Hub doesn\'t have that scene. Update its firmware.' : 'The Hub couldn\'t do that. Try again.';
    case HubError.badResponse:
      return 'The Hub sent a reply the app didn\'t understand. Updating the firmware may help.';
    case HubError.unknown:
      return 'Something went wrong. Open Diagnostics for details.';
  }
}

/// Why a Wi-Fi join failed on the board (value of "reason" in /api/wifi/status).
enum JoinFailure { badPassword, notFound, unsupportedSecurity, assocFailed, weakSignal, dhcpTimeout, routerUnavailable, networkDisconnected, deviceReboot, invalidCredentials, ownHotspot, timeout, unknown }

JoinFailure joinFailureFrom(String? reason) {
  switch (reason) {
    case 'bad_password':
      return JoinFailure.badPassword;
    case 'not_found':
      return JoinFailure.notFound;
    case 'unsupported_security':
      return JoinFailure.unsupportedSecurity;
    case 'assoc_failed':
      return JoinFailure.assocFailed;
    case 'weak_signal':
      return JoinFailure.weakSignal;
    case 'dhcp_timeout':
      return JoinFailure.dhcpTimeout;
    case 'router_unavailable':
      return JoinFailure.routerUnavailable;
    case 'invalid_credentials':
      return JoinFailure.invalidCredentials;
    case 'own_hotspot':
      return JoinFailure.ownHotspot;
    case 'timeout':
      return JoinFailure.timeout;
    default:
      return JoinFailure.unknown;
  }
}

String joinFailureText(JoinFailure f) {
  switch (f) {
    case JoinFailure.badPassword:
      return 'The Hub couldn\'t join this network. Check the password and try again.';
    case JoinFailure.notFound:
      return 'The Hub can\'t see a network with that name. Check the spelling (capitals count), that it is a 2.4 GHz network, and that the router is close to the Hub.';
    case JoinFailure.unsupportedSecurity:
      return 'This network uses a security mode the Hub doesn\'t support. Use WPA2 on a 2.4 GHz network.';
    case JoinFailure.assocFailed:
      return 'The router refused the connection. It may have too many devices, or MAC filtering is on.';
    case JoinFailure.weakSignal:
      return 'The signal is too weak at the Hub. Move the router or the Hub closer and try again.';
    case JoinFailure.dhcpTimeout:
      return 'The Hub reached the router but didn\'t get an address. Restart the router and try again.';
    case JoinFailure.routerUnavailable:
      return 'The router dropped the connection. Check that it is working and try again.';
    case JoinFailure.networkDisconnected:
      return 'Your phone lost the Hub\'s Wi-Fi during setup. Rejoin it and try again.';
    case JoinFailure.deviceReboot:
      return 'The Hub restarted during setup. Wait a few seconds and try again.';
    case JoinFailure.invalidCredentials:
      return 'The network name or password isn\'t valid. Names are up to 32 characters; passwords are 8 to 63 characters.';
    case JoinFailure.ownHotspot:
      return 'That is the Hub\'s own hotspot. Choose your home Wi-Fi.';
    case JoinFailure.timeout:
    case JoinFailure.unknown:
      return 'The Hub couldn\'t join this network in time. Check the password and signal strength, then try again.';
  }
}
