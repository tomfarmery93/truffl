package com.trufflpets.app;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.location.Location;
import android.location.LocationListener;
import android.location.LocationManager;
import android.os.Build;
import android.os.Bundle;
import android.os.IBinder;
import android.os.Looper;
import android.util.Log;

import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;

import org.json.JSONObject;

import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Foreground service that collects GPS fixes and uploads each as a gps_pings row to
 * Supabase from native code, so tracking survives the screen being off / the app
 * being backgrounded (where the WebView's JS is suspended). See WalkTrackerPlugin.
 *
 * Logs under tag "TrufflWalk" — filter Logcat by that tag when debugging.
 */
public class WalkTrackingService extends Service implements LocationListener {

  private static final String TAG = "TrufflWalk";
  private static final String CHANNEL_ID = "truffl_walk_tracking";
  private static final int NOTIF_ID = 4201;

  // Drop obviously-bad fixes and stationary GPS noise.
  private static final float MAX_ACCURACY_M = 50f;
  private static final float MIN_MOVE_M = 8f;

  private LocationManager locationManager;
  private ExecutorService executor;
  private String supabaseUrl, anonKey, accessToken, walkSessionId;
  private long intervalMs = 10000;
  private long lastSent = 0;
  private Location lastRecorded = null;

  @Override
  public void onCreate() {
    super.onCreate();
    executor = Executors.newSingleThreadExecutor();
    locationManager = (LocationManager) getSystemService(Context.LOCATION_SERVICE);
  }

  @Override
  public int onStartCommand(Intent intent, int flags, int startId) {
    if (intent != null) {
      supabaseUrl = intent.getStringExtra("supabaseUrl");
      anonKey = intent.getStringExtra("anonKey");
      accessToken = intent.getStringExtra("accessToken");
      walkSessionId = intent.getStringExtra("walkSessionId");
      intervalMs = intent.getIntExtra("intervalMs", 10000);
    }
    Log.d(TAG, "Service start — session=" + walkSessionId + " interval=" + intervalMs + "ms");
    startForegroundWithNotification();
    requestLocationUpdates();
    return START_STICKY;
  }

  private void startForegroundWithNotification() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      NotificationChannel channel = new NotificationChannel(
        CHANNEL_ID, "Walk tracking", NotificationManager.IMPORTANCE_LOW);
      NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
      if (nm != null) nm.createNotificationChannel(channel);
    }
    Notification notification = new NotificationCompat.Builder(this, CHANNEL_ID)
      .setContentTitle("Truffl — walk in progress")
      .setContentText("Tracking the walk so the owner can follow along live.")
      .setSmallIcon(android.R.drawable.ic_menu_mylocation)
      .setOngoing(true)
      .build();

    try {
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) { // API 34+
        startForeground(NOTIF_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION);
      } else {
        startForeground(NOTIF_ID, notification);
      }
      Log.d(TAG, "Foreground notification started");
    } catch (Exception e) {
      Log.e(TAG, "startForeground failed", e);
    }
  }

  private void requestLocationUpdates() {
    try {
      // Ask for updates ~every 5s; we throttle persistence to intervalMs + a movement filter below.
      long minTime = Math.min(5000, intervalMs);
      if (locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)) {
        locationManager.requestLocationUpdates(LocationManager.GPS_PROVIDER, minTime, 0, this, Looper.getMainLooper());
        Log.d(TAG, "Requested GPS_PROVIDER updates");
      }
      if (locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) {
        locationManager.requestLocationUpdates(LocationManager.NETWORK_PROVIDER, minTime, 0, this, Looper.getMainLooper());
      }
    } catch (SecurityException e) {
      Log.e(TAG, "Location permission missing when requesting updates", e);
    }
  }

  @Override
  public void onLocationChanged(Location location) {
    if (location == null) return;

    if (location.hasAccuracy() && location.getAccuracy() > MAX_ACCURACY_M) {
      Log.d(TAG, "skip fix: poor accuracy " + Math.round(location.getAccuracy()) + "m");
      return;
    }

    long now = System.currentTimeMillis();
    boolean first = (lastRecorded == null);
    if (!first) {
      if (now - lastSent < intervalMs) return;                       // time throttle
      if (location.distanceTo(lastRecorded) < MIN_MOVE_M) {          // stationary filter
        Log.d(TAG, "skip fix: moved <" + (int) MIN_MOVE_M + "m");
        return;
      }
    }

    lastSent = now;
    lastRecorded = location;
    Log.d(TAG, "record fix: " + location.getLatitude() + "," + location.getLongitude()
      + " acc=" + Math.round(location.getAccuracy()) + "m");
    postPing(location.getLatitude(), location.getLongitude(), location.getAccuracy());
  }

  private void postPing(final double lat, final double lng, final float accuracy) {
    executor.execute(() -> {
      HttpURLConnection conn = null;
      try {
        URL url = new URL(supabaseUrl + "/rest/v1/gps_pings");
        conn = (HttpURLConnection) url.openConnection();
        conn.setRequestMethod("POST");
        conn.setRequestProperty("Content-Type", "application/json");
        conn.setRequestProperty("apikey", anonKey);
        conn.setRequestProperty("Authorization", "Bearer " + accessToken);
        conn.setRequestProperty("Prefer", "return=minimal");
        conn.setConnectTimeout(15000);
        conn.setReadTimeout(15000);
        conn.setDoOutput(true);

        SimpleDateFormat iso = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US);
        iso.setTimeZone(TimeZone.getTimeZone("UTC"));

        JSONObject body = new JSONObject();
        body.put("walk_session_id", walkSessionId);
        body.put("lat", lat);
        body.put("lng", lng);
        body.put("accuracy_metres", Math.round(accuracy));
        body.put("recorded_at", iso.format(new Date()));

        OutputStream os = conn.getOutputStream();
        os.write(body.toString().getBytes("UTF-8"));
        os.flush();
        os.close();

        int code = conn.getResponseCode();
        if (code >= 200 && code < 300) {
          Log.d(TAG, "ping POST ok (" + code + ")");
        } else {
          Log.e(TAG, "ping POST failed: HTTP " + code);
        }
      } catch (Exception e) {
        Log.e(TAG, "ping POST exception", e);
      } finally {
        if (conn != null) conn.disconnect();
      }
    });
  }

  @Override
  public void onDestroy() {
    Log.d(TAG, "Service destroy");
    try { if (locationManager != null) locationManager.removeUpdates(this); } catch (Exception e) {}
    if (executor != null) executor.shutdown();
    super.onDestroy();
  }

  @Nullable
  @Override
  public IBinder onBind(Intent intent) { return null; }

  @Override public void onStatusChanged(String provider, int status, Bundle extras) {}
  @Override public void onProviderEnabled(String provider) {}
  @Override public void onProviderDisabled(String provider) {}
}
