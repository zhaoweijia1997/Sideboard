package com.weijiazhao.sideboard

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Notes the exact start-up time, catches up on history and makes sure the job is scheduled. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        Thread {
            runCatching {
                if (intent.action == Intent.ACTION_BOOT_COMPLETED) History.recordBoot(context)
                History.record(context)
                RecordJob.schedule(context)
            }
            pending.finish()
        }.start()
    }
}
