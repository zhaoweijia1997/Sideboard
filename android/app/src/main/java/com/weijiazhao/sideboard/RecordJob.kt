package com.weijiazhao.sideboard

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context

/**
 * Copies the usage history every few hours. Android picks when within that window and batches it
 * with other work, so it costs next to nothing; there is no service running in between.
 */
class RecordJob : JobService() {
    override fun onStartJob(params: JobParameters): Boolean {
        Thread {
            runCatching { History.record(applicationContext) }
            jobFinished(params, false)
        }.start()
        return true
    }

    override fun onStopJob(params: JobParameters) = true

    companion object {
        const val ID = 1
        private const val EVERY = 3 * 3_600_000L

        fun schedule(context: Context) {
            val scheduler = context.getSystemService(JobScheduler::class.java)
            if (scheduler.getPendingJob(ID) != null) return
            scheduler.schedule(
                JobInfo.Builder(ID, ComponentName(context, RecordJob::class.java))
                    .setPeriodic(EVERY, EVERY / 3)
                    .setPersisted(true)
                    .build(),
            )
        }
    }
}
