/*
 * JBoss, Home of Professional Open Source.
 * Copyright Red Hat, Inc., and individual contributors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package org.jboss.aerogear.cordova.oauth2;

import android.accounts.AccountManager;
import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.util.Log;
import com.google.android.gms.auth.GoogleAuthUtil;
import com.google.android.gms.auth.UserRecoverableAuthException;
import com.google.android.gms.common.AccountPicker;
import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaInterface;

public class OauthGoogleServicesIntentHelper {
  private static final String TAG = "OauthGoogleServices";
  private static final int REQUEST_CODE_PICK_ACCOUNT = 1000;
  private static final int REQUEST_AUTHORIZATION = 2;
  private static final String KEY_AUTH_TOKEN = "authtoken";
  private static final String PROFILE_SCOPE = "https://www.googleapis.com/auth/plus.me";
  private String scopes;
  private CallbackContext callbackContext;
  public CordovaInterface cordova;

  public OauthGoogleServicesIntentHelper(CordovaInterface cordova, CallbackContext callbackContext) {
    this.cordova = cordova;
    this.callbackContext = callbackContext;
  }

  public boolean triggerIntent(final String plainScopes) {
    scopes = "oauth2:" + (plainScopes.isEmpty() ? PROFILE_SCOPE : plainScopes);
    Runnable runnable = new Runnable() {
      public void run() {
        try {
          Intent intent = AccountPicker.newChooseAccountIntent(null, null,
                  new String[]{GoogleAuthUtil.GOOGLE_ACCOUNT_TYPE}, false, null, null, null, null);
          cordova.getActivity().startActivityForResult(intent, REQUEST_CODE_PICK_ACCOUNT);
        } catch (ActivityNotFoundException e) {
          Log.e(TAG, "Activity not found: " + e.toString());
          callbackContext.error("Plugin cannot find activity: " + e.toString());
        } catch (Exception e) {
          Log.e(TAG, "Exception: " + e.toString());
          callbackContext.error("Plugin failed to get account: " + e.toString());
        }
      }

      ;
    };
    cordova.getActivity().runOnUiThread(runnable);
    return true;
  }

  public void onActivityResult(int requestCode, int resultCode, final Intent data) {
    if (callbackContext != null) {
      try {
        if (requestCode == REQUEST_CODE_PICK_ACCOUNT) {
          if (resultCode == Activity.RESULT_OK) {
            String accountName = data.getStringExtra(AccountManager.KEY_ACCOUNT_NAME);
            Log.i(TAG, "account:" + accountName);
            getToken(accountName);
          } else {
            callbackContext.error("plugin failed to get account");
          }
        } else if (requestCode == REQUEST_AUTHORIZATION) {
          if (resultCode == Activity.RESULT_OK) {
            String token = data.getStringExtra(KEY_AUTH_TOKEN);
            callbackContext.success(token);
          } else {
            callbackContext.error("plugin failed to get token");
          }
        } else {
          Log.i(TAG, "Unhandled activityResult. requestCode: " + requestCode + " resultCode: " + resultCode);
        }
      } catch (Exception e) {
        callbackContext.error("Plugin failed to get email: " + e.toString());
        Log.e(TAG, "Exception: " + e.toString());
      }
    } else {
      Log.d(TAG, "No callback to go to!");
    }
  }

  private void getToken(final String accountName) {
    Runnable runnable = new Runnable() {
      public void run() {
        String token;
        try {
          Log.e(TAG, "Retrieving token for: " + accountName);
          Log.e(TAG, "with scope(s): " + scopes);
          token = GoogleAuthUtil.getToken(cordova.getActivity(), accountName, scopes);
          callbackContext.success(token);
        } catch (UserRecoverableAuthException userRecoverableException) {
          Log.e(TAG, "UserRecoverableAuthException: Attempting recovery...");
          cordova.getActivity().startActivityForResult(userRecoverableException.getIntent(), REQUEST_AUTHORIZATION);
        } catch (Exception e) {
          Log.i(TAG, "error" + e.getMessage());
          callbackContext.error("plugin failed to get token: " + e.getMessage());
        }
      }
    };
    cordova.getThreadPool().execute(runnable);
  }
}
