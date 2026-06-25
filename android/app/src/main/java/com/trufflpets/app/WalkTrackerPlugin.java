package com.trufflpets.app;

import android.Manifest;
import android.content.Intent;
import android.os.Build;

import com.getcapacitor.PermissionState;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;

/**
 * TRU-56: native background walk tracking.
 *
 * The web page's JS is throttled/suspended when the screen is off or the app is
 * backgrounded, so persisting GPS pings from JS is unreliable. This plugin runs a
 * foreground service that collects locations and POSTs them to Supabase from native
 * code, independent of the WebView — so tracking continues with the app off-screen.
 *
 * We only request "while in use" (fine) location: a foreground service of type
 * `location` started while the app is visible may keep accessing location in the
 * background, so ACCESS_BACKGROUND_LOCATION isn't required.
 */
@CapacitorPlugin(
  name = "TrufflWalkTracker",
  permissions = {
    @Permission(
      alias = "location",
      strings = { Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION }
    )
  }
)
public class WalkTrackerPlugin extends Plugin {

  @PluginMethod
  public void start(PluginCall call) {
    if (getPermissionState("location") != PermissionState.GRANTED) {
      // Persist the call and request the runtime prompt; resumes in the callback.
      bridge.saveCall(call);
      requestPermissionForAlias("location", call, "locationPermsCallback");
      return;
    }
    startTracking(call);
  }

  @PermissionCallback
  private void locationPermsCallback(PluginCall call) {
    if (getPermissionState("location") == PermissionState.GRANTED) {
      startTracking(call);
    } else {
      call.reject("Location permission denied");
    }
  }

  private void startTracking(PluginCall call) {
    String supabaseUrl = call.getString("supabaseUrl");
    String anonKey = call.getString("anonKey");
    String accessToken = call.getString("accessToken");
    String walkSessionId = call.getString("walkSessionId");
    Integer intervalMs = call.getInt("intervalMs", 10000);

    if (supabaseUrl == null || anonKey == null || accessToken == null || walkSessionId == null) {
      call.reject("Missing required tracking config (supabaseUrl, anonKey, accessToken, walkSessionId)");
      return;
    }

    Intent intent = new Intent(getContext(), WalkTrackingService.class);
    intent.putExtra("supabaseUrl", supabaseUrl);
    intent.putExtra("anonKey", anonKey);
    intent.putExtra("accessToken", accessToken);
    intent.putExtra("walkSessionId", walkSessionId);
    intent.putExtra("intervalMs", intervalMs);

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      getContext().startForegroundService(intent);
    } else {
      getContext().startService(intent);
    }
    call.resolve();
  }

  @PluginMethod
  public void stop(PluginCall call) {
    getContext().stopService(new Intent(getContext(), WalkTrackingService.class));
    call.resolve();
  }
}
