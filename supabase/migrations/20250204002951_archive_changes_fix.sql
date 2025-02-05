DROP TRIGGER IF EXISTS queue_job_on_upload_complete ON public.archive_upload;
DROP TRIGGER IF EXISTS queue_job_on_upload_delete ON public.archive_upload;


CREATE OR REPLACE FUNCTION private.queue_archive_changes()
RETURNS TRIGGER AS $$
BEGIN
RAISE NOTICE 'queue_archive_changes:Queueing job: archive_changes';
INSERT INTO private.job_queue (key, status)
VALUES ('archive_changes', 'QUEUED')
ON CONFLICT (key) DO UPDATE
SET timestamp = CURRENT_TIMESTAMP,
    status = 'QUEUED';

RETURN NEW;
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER queue_job_on_upload_complete
AFTER UPDATE OF upload_phase ON public.archive_upload
FOR EACH ROW
WHEN (NEW.upload_phase = 'completed')
EXECUTE FUNCTION private.queue_archive_changes();

CREATE TRIGGER queue_job_on_upload_delete
AFTER DELETE ON public.archive_upload
FOR EACH ROW
EXECUTE FUNCTION private.queue_archive_changes();