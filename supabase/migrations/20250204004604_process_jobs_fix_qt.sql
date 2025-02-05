
CREATE OR REPLACE FUNCTION private.process_jobs()
RETURNS void AS $$
DECLARE
v_job RECORD;
BEGIN
RAISE NOTICE 'Starting process_jobs';

-- Check for a job
SELECT * INTO v_job
FROM private.job_queue
WHERE status = 'QUEUED'
ORDER BY timestamp
LIMIT 1
FOR UPDATE SKIP LOCKED;

-- If no job, exit
IF NOT FOUND THEN
    RAISE NOTICE 'No jobs found, exiting';
    RETURN;
END IF;

RAISE NOTICE 'Processing job: %', v_job.key;

-- Update job status to PROCESSING
UPDATE private.job_queue
SET status = 'PROCESSING'
WHERE key = v_job.key;

-- Do the job
IF v_job.key = 'archive_changes' THEN
    RAISE NOTICE 'Refreshing materialized views concurrently';
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.global_activity_summary;
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.account_activity_summary;
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.quote_tweets_mv;
    PERFORM private.post_upload_update_conversation_ids();
END IF;

IF v_job.key = 'update_conversation_ids' THEN
    RAISE NOTICE 'Updating conversation ids';
    
END IF;

-- Delete the job
DELETE FROM private.job_queue WHERE key = v_job.key;
RAISE NOTICE 'Job completed and removed from queue: %', v_job.key;
END;
$$ LANGUAGE plpgsql;
-- Enable pg_cron extension if not already enabled
CREATE EXTENSION IF NOT EXISTS pg_cron;
DO $$
DECLARE
    job_id bigint;
BEGIN
    FOR job_id IN 
        SELECT jobid 
        FROM cron.job 
        WHERE command LIKE '%SELECT private.process_jobs();%'
    LOOP
        PERFORM cron.unschedule(job_id);
        RAISE NOTICE 'Unscheduled job with ID: %', job_id;
    END LOOP;
END $$;
-- Schedule job to run every minute
SELECT cron.schedule('* * * * *', $$
SELECT private.process_jobs();
$$);

