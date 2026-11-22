# LocaShare Family — Supabase Free-Tier Cloud Setup

Use this setup to run **LocaShare Family** over mobile data with **zero server hosting** and **zero credit card** required.

## 1. Create a Free Supabase Project
1. Sign up at [supabase.com](https://supabase.com) and create a new project.
2. Open **SQL Editor** in your Supabase dashboard, paste the entire contents of [`schema.sql`](schema.sql), and click **Run**.
3. Go to **Project Settings → API** and copy:
   - **Project URL** (e.g. `https://xyzcompany.supabase.co`)
   - **anon public key**

## 2. Connect the LocaShare Mobile App
1. Open **LocaShare** on each family phone.
2. Go to the **Circle & Device** tab → **Backend Mode** → select **Supabase Cloud**.
3. Paste your **Project URL** and **anon public key**, then tap **Save & Test**.
4. Tap **Register this device**, then on one phone tap **Create Family Circle** (e.g. `"Our Family"`) to receive a shareable invite code (`FAM-XXXX-XXXX`).
5. On other family phones, tap **Join Family Circle** and enter that invite code.
6. Go to **Places & Alerts** → tap **Set Home Location** (or pick on map) so LocaShare automatically switches between **At Home (Battery Saver & Privacy)** and **Away (Live GPS)**.

## 3. Optional: Real-Time FCM Push Notifications When App Is Closed
Even without Firebase Cloud Messaging (FCM), LocaShare's background service checks recent family place events and posts local Android system notifications when family members leave or arrive at Home, School, or Work.

To also deliver instant wake-up FCM pushes when a phone's screen is off or background service is stopped:
1. Create a free Firebase project in the Firebase Console and download a **Service Account JSON** (`Project Settings → Service accounts → Generate new private key`).
2. Deploy the Edge Function:
   ```bash
   supabase functions deploy place-event-notify --no-verify-jwt
   supabase secrets set \
     FCM_PROJECT_ID=your-firebase-project-id \
     FCM_CLIENT_EMAIL=firebase-adminsdk-xxx@your-project.iam.gserviceaccount.com \
     FCM_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n"
   ```
3. Add your Android app's `google-services.json` to `mobile/android/app/` if you compile FCM token collection into your APK.
