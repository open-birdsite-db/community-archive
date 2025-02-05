-- drop function if exists "private"."queue_archive_changes"();
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'readclient') THEN
        CREATE ROLE readclient;
    END IF;
END
$$;


alter table "private"."logs" drop constraint "logs_pkey";

drop index if exists "private"."logs_pkey";

drop table "private"."logs";

drop sequence if exists "private"."logs_log_id_seq";

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION private.commit_temp_data_test(p_suffix text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET statement_timeout TO '30min'
AS $function$
DECLARE
    v_archive_upload_id BIGINT;
    v_account_id TEXT;
    v_archive_at TIMESTAMP WITH TIME ZONE;
    v_keep_private BOOLEAN;
    v_upload_likes BOOLEAN;
    v_start_date DATE;
    v_end_date DATE;
BEGIN
    IF auth.uid() IS NULL AND current_user != 'postgres' THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;
    RAISE NOTICE 'commit_temp_data called with suffix: %', p_suffix;
    
    RAISE NOTICE 'Phase 1: Inserting account data';
    -- 1. Insert account data first
    EXECUTE format('
        INSERT INTO public.all_account (
            created_via, username, account_id, created_at, account_display_name,
            num_tweets, num_following, num_followers, num_likes
        )
        SELECT 
            created_via, username, account_id, created_at, account_display_name,
            num_tweets, num_following, num_followers, num_likes
        FROM temp.account_%s
        ON CONFLICT (account_id) DO UPDATE SET
            username = EXCLUDED.username,
            account_display_name = EXCLUDED.account_display_name,
            created_via = EXCLUDED.created_via,
            created_at = EXCLUDED.created_at,
            num_tweets = EXCLUDED.num_tweets,
            num_following = EXCLUDED.num_following,
            num_followers = EXCLUDED.num_followers,
            num_likes = EXCLUDED.num_likes
        RETURNING account_id
    ', p_suffix) INTO v_account_id;

    RAISE NOTICE 'Phase 2: Getting archive upload data';
    -- 2. Get the latest archive upload data from temp.archive_upload
    EXECUTE format('
        SELECT archive_at, keep_private, upload_likes, start_date, end_date
        FROM temp.archive_upload_%s
        ORDER BY archive_at DESC
        LIMIT 1
    ', p_suffix) INTO v_archive_at, v_keep_private, v_upload_likes, v_start_date, v_end_date;

    RAISE NOTICE 'Phase 3: Inserting archive upload data';
    -- 3. Insert or update archive_upload and get the ID
    INSERT INTO public.archive_upload (
        account_id, 
        archive_at, 
        created_at, 
        keep_private, 
        upload_likes, 
        start_date, 
        end_date,
        upload_phase
    )
    VALUES (
        v_account_id, 
        v_archive_at, 
        CURRENT_TIMESTAMP, 
        v_keep_private, 
        v_upload_likes, 
        v_start_date, 
        v_end_date,
        'uploading'
    )
    ON CONFLICT (account_id, archive_at)
    DO UPDATE SET
        account_id = EXCLUDED.account_id,
        created_at = CURRENT_TIMESTAMP,
        keep_private = EXCLUDED.keep_private,
        upload_likes = EXCLUDED.upload_likes,
        start_date = EXCLUDED.start_date,
        end_date = EXCLUDED.end_date,
        upload_phase = 'uploading'
    RETURNING id INTO v_archive_upload_id;

    RAISE NOTICE 'Phase 4: Inserting profile data';
    -- Insert profile data
    EXECUTE format('
        INSERT INTO public.all_profile (bio, website, location, avatar_media_url, header_media_url, account_id, archive_upload_id)
        SELECT p.bio, p.website, p.location, p.avatar_media_url, p.header_media_url, p.account_id, $1
        FROM temp.profile_%s p
        ON CONFLICT (account_id) DO UPDATE SET
            bio = EXCLUDED.bio,
            website = EXCLUDED.website,
            location = EXCLUDED.location,
            avatar_media_url = EXCLUDED.avatar_media_url,
            header_media_url = EXCLUDED.header_media_url,
            archive_upload_id = EXCLUDED.archive_upload_id
    ', p_suffix) USING v_archive_upload_id;

    RAISE NOTICE 'Phase 5: Inserting tweets data';
    -- Insert tweets data
    EXECUTE format('
        INSERT INTO public.tweets (tweet_id, account_id, created_at, full_text, retweet_count, favorite_count, reply_to_tweet_id, reply_to_user_id, reply_to_username, archive_upload_id)
        SELECT t.tweet_id, t.account_id, t.created_at, t.full_text, t.retweet_count, t.favorite_count, t.reply_to_tweet_id, t.reply_to_user_id, t.reply_to_username, $1
        FROM temp.tweets_%s t
        ON CONFLICT (tweet_id) DO UPDATE SET
            full_text = EXCLUDED.full_text,
            retweet_count = EXCLUDED.retweet_count,
            favorite_count = EXCLUDED.favorite_count,
            reply_to_tweet_id = EXCLUDED.reply_to_tweet_id,
            reply_to_user_id = EXCLUDED.reply_to_user_id,
            reply_to_username = EXCLUDED.reply_to_username,
            archive_upload_id = EXCLUDED.archive_upload_id
    ', p_suffix) USING v_archive_upload_id;

    RAISE NOTICE 'Phase 6: Inserting tweet media data';
    -- Insert tweet_media data
    EXECUTE format('
        INSERT INTO public.tweet_media (media_id, tweet_id, media_url, media_type, width, height, archive_upload_id)
        SELECT tm.media_id, tm.tweet_id, tm.media_url, tm.media_type, tm.width, tm.height, $1
        FROM temp.tweet_media_%s tm
        ON CONFLICT (media_id) DO UPDATE SET
            media_url = EXCLUDED.media_url,
            media_type = EXCLUDED.media_type,
            width = EXCLUDED.width,
            height = EXCLUDED.height,
            archive_upload_id = EXCLUDED.archive_upload_id
    ', p_suffix) USING v_archive_upload_id;

    RAISE NOTICE 'Phase 7: Inserting mentioned users data';
    -- Insert mentioned_users data
    EXECUTE format('
        INSERT INTO public.mentioned_users (user_id, name, screen_name, updated_at)
        SELECT user_id, name, screen_name, updated_at
        FROM temp.mentioned_users_%s
        ON CONFLICT (user_id) DO UPDATE SET
            name = EXCLUDED.name,
            screen_name = EXCLUDED.screen_name,
            updated_at = EXCLUDED.updated_at
    ', p_suffix);

    RAISE NOTICE 'Phase 8: Inserting user mentions data';
    -- Insert user_mentions data
    EXECUTE format('
        INSERT INTO public.user_mentions (mentioned_user_id, tweet_id)
        SELECT um.mentioned_user_id, um.tweet_id
        FROM temp.user_mentions_%s um
        JOIN public.mentioned_users mu ON um.mentioned_user_id = mu.user_id
        JOIN public.tweets t ON um.tweet_id = t.tweet_id
        ON CONFLICT (mentioned_user_id, tweet_id) DO NOTHING
    ', p_suffix);

    RAISE NOTICE 'Phase 9: Inserting tweet URLs data';
    -- Insert tweet_urls data
    EXECUTE format('
        INSERT INTO public.tweet_urls (url, expanded_url, display_url, tweet_id)
        SELECT tu.url, tu.expanded_url, tu.display_url, tu.tweet_id
        FROM temp.tweet_urls_%s tu
        JOIN public.tweets t ON tu.tweet_id = t.tweet_id
        ON CONFLICT (tweet_id, url) DO NOTHING
    ', p_suffix);

    RAISE NOTICE 'Phase 10: Inserting followers data';
    -- Insert followers data
    EXECUTE format('
        INSERT INTO public.followers (account_id, follower_account_id, archive_upload_id)
        SELECT f.account_id, f.follower_account_id, $1
        FROM temp.followers_%s f
        ON CONFLICT (account_id, follower_account_id) DO UPDATE SET
            archive_upload_id = EXCLUDED.archive_upload_id
    ', p_suffix) USING v_archive_upload_id;

    RAISE NOTICE 'Phase 11: Inserting following data';
    -- Insert following data
    EXECUTE format('
        INSERT INTO public.following (account_id, following_account_id, archive_upload_id)
        SELECT f.account_id, f.following_account_id, $1
        FROM temp.following_%s f
        ON CONFLICT (account_id, following_account_id) DO UPDATE SET
            archive_upload_id = EXCLUDED.archive_upload_id
    ', p_suffix) USING v_archive_upload_id;

    RAISE NOTICE 'Phase 12: Inserting liked tweets data';
    -- Insert liked_tweets data
    EXECUTE format('
        INSERT INTO public.liked_tweets (tweet_id, full_text)
        SELECT lt.tweet_id, lt.full_text
        FROM temp.liked_tweets_%s lt
        ON CONFLICT (tweet_id) DO NOTHING
    ', p_suffix);

    RAISE NOTICE 'Phase 13: Inserting likes data';
    -- Insert likes data
    EXECUTE format('
        INSERT INTO public.likes (account_id, liked_tweet_id, archive_upload_id)
        SELECT l.account_id, l.liked_tweet_id, $1
        FROM temp.likes_%s l
        ON CONFLICT (account_id, liked_tweet_id) DO UPDATE SET
            archive_upload_id = EXCLUDED.archive_upload_id
    ', p_suffix) USING v_archive_upload_id;

    RAISE NOTICE 'Phase 14: Dropping temporary tables';
    -- Drop temporary tables after committing
    PERFORM public.drop_temp_tables(p_suffix);

    RAISE NOTICE 'Phase 15: Updating upload phase to completed';
    -- Update upload_phase to 'completed' after successful execution
    UPDATE public.archive_upload
    SET upload_phase = 'completed'
    WHERE id = v_archive_upload_id;

EXCEPTION
    WHEN OTHERS THEN
        -- Update upload_phase to 'failed' if an error occurs
        UPDATE public.archive_upload
        SET upload_phase = 'failed'
        WHERE id = v_archive_upload_id;
        RAISE;
END;
$function$
;

CREATE OR REPLACE FUNCTION private.count_liked_tweets_in_replies()
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    liked_tweets_count BIGINT;
BEGIN
    -- This function counts how many of the tweets in the liked_tweets table
    -- are present in the reply_to_tweet_id column of the tweet_replies_view.
    
    SELECT
        COUNT(*) INTO liked_tweets_count
    FROM
        public.liked_tweets lt
    JOIN
        public.tweet_replies_view tr ON lt.tweet_id = tr.reply_to_tweet_id;

    RETURN liked_tweets_count;
END;
$function$
;

CREATE OR REPLACE FUNCTION private.get_reply_to_user_counts()
 RETURNS TABLE(unique_reply_to_users bigint, mentioned_users_count bigint)
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- This function returns the count of unique users in the reply_to_user_id column
    -- of the public.tweets table and the count of those users that exist in the
    -- public.mentioned_users table.
    
    RETURN QUERY
    SELECT 
        COUNT(DISTINCT t.reply_to_user_id) AS unique_reply_to_users,
        COUNT(DISTINCT mu.user_id) AS mentioned_users_count
    FROM 
        public.tweets t
    LEFT JOIN 
        public.mentioned_users mu ON t.reply_to_user_id = mu.user_id
    WHERE 
        t.reply_to_user_id IS NOT NULL;
END;
$function$
;

CREATE OR REPLACE FUNCTION private.queue_update_conversation_ids()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE NOTICE 'queue_update_conversation_ids:Queueing job: update_conversation_ids';
    INSERT INTO private.job_queue (key, status)
    VALUES ('update_conversation_ids', 'QUEUED')
    ON CONFLICT (key) DO UPDATE
    SET timestamp = CURRENT_TIMESTAMP,
        status = 'QUEUED';

    
    RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION private.process_jobs()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
IF v_job.key = 'refresh_activity_summary' THEN
    RAISE NOTICE 'Refreshing materialized views';
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.global_activity_summary;
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.account_activity_summary;
END IF;


IF v_job.key = 'update_conversation_ids' THEN
    RAISE NOTICE 'Updating conversation ids';
    PERFORM private.post_upload_update_conversation_ids();
END IF;

-- Delete the job
DELETE FROM private.job_queue WHERE key = v_job.key;
RAISE NOTICE 'Job completed and removed from queue: %', v_job.key;
END;
$function$
;

CREATE OR REPLACE FUNCTION private.tes_complete_group_insertions()
 RETURNS TABLE(completed integer, errors text[])
 LANGUAGE plpgsql
AS $function$
DECLARE
    completed_count INTEGER := 0;
    error_records TEXT[];
BEGIN
    BEGIN
        WITH api_groups AS (
            SELECT DISTINCT originator_id
            FROM temporary_data td1
            WHERE 
                -- Find groups where all records are API-type
                type LIKE 'api%'
                AND NOT EXISTS (
                    SELECT 1 
                    FROM temporary_data td2 
                    WHERE td2.originator_id = td1.originator_id 
                    AND td2.type NOT LIKE 'api%'
                    AND td2.inserted IS NULL
                )
        ),
        updates AS (
            UPDATE temporary_data td
            SET inserted = CURRENT_TIMESTAMP
            FROM api_groups ag
            WHERE td.originator_id = ag.originator_id
            AND td.type LIKE 'api%'
            AND td.inserted IS NULL
            RETURNING td.originator_id
        )
        SELECT COUNT(DISTINCT originator_id), array_agg(DISTINCT originator_id)
        INTO completed_count, error_records
        FROM updates;
        RETURN QUERY SELECT completed_count, error_records;
  
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT -1, ARRAY[SQLERRM];
    END;
END;
$function$
;

CREATE OR REPLACE FUNCTION private.tes_import_temporary_data_into_tables()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    account_result RECORD;
    profile_result RECORD;
    tweet_result RECORD;
    media_result RECORD;
    url_result RECORD;
    mention_result RECORD;
BEGIN
    RAISE NOTICE 'Starting tes_import_temporary_data_into_tables';
    -- Process accounts and capture results
    SELECT * INTO account_result FROM private.tes_process_account_records();
    RAISE NOTICE 'Processed % accounts with % errors', account_result.processed, array_length(account_result.errors, 1);
    -- Process profiles and capture results  
    SELECT * INTO profile_result FROM private.tes_process_profile_records();
    RAISE NOTICE 'Processed % profiles with % errors', profile_result.processed, array_length(profile_result.errors, 1);
    -- Process tweets and capture results
    SELECT * INTO tweet_result FROM private.tes_process_tweet_records();
    RAISE NOTICE 'Processed % tweets with % errors', tweet_result.processed, array_length(tweet_result.errors, 1);
    -- Process media and capture results
    SELECT * INTO media_result FROM private.tes_process_media_records();
    RAISE NOTICE 'Processed % media with % errors', media_result.processed, array_length(media_result.errors, 1);
    -- Process urls and capture results
    SELECT * INTO url_result FROM private.tes_process_url_records();
    RAISE NOTICE 'Processed % urls with % errors', url_result.processed, array_length(url_result.errors, 1);
    -- Process mentions and capture results
    SELECT * INTO mention_result FROM private.tes_process_mention_records();
    RAISE NOTICE 'Processed % mentions with % errors', mention_result.processed, array_length(mention_result.errors, 1);
    PERFORM private.tes_complete_group_insertions();
    RAISE NOTICE 'Job completed';
EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'Error in tes_import_temporary_data_into_tables: %', SQLERRM;
END;
$function$
;

CREATE OR REPLACE FUNCTION private.tes_invoke_edge_function_move_data_to_storage()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    request_id TEXT;
    response_status INTEGER;
    start_time TIMESTAMP;
    elapsed_seconds NUMERIC;
BEGIN
    PERFORM net.http_post(
        url:='https://fabxmporizzqflnftavs.supabase.co/functions/v1/schedule_data_moving'
    );
END;
$function$
;

CREATE OR REPLACE FUNCTION private.tes_process_account_records()
 RETURNS TABLE(processed integer, errors text[])
 LANGUAGE plpgsql
AS $function$
DECLARE
    processed_count INTEGER := 0;
    error_records TEXT[];
    processed_ids TEXT[];
BEGIN
    BEGIN
        WITH latest_records AS (
            SELECT *,
                ROW_NUMBER() OVER (
                    PARTITION BY (data->>'account_id')::text 
                    ORDER BY (data->>'created_at')::timestamp with time zone DESC
                ) as rn
            FROM temporary_data 
            WHERE type = 'import_account' 
            AND (data->>'account_id')::text IS NOT NULL
            AND inserted IS NULL
        ),
        insertions AS (
            INSERT INTO public.all_account
            SELECT 
                (data->>'account_id')::text,
                (data->>'created_via')::text,
                (data->>'username')::text,
                (data->>'created_at')::timestamp with time zone,
                (data->>'account_display_name')::text,
                NULLIF((data->>'num_tweets')::text, '')::integer,
                NULLIF((data->>'num_following')::text, '')::integer,
                NULLIF((data->>'num_followers')::text, '')::integer,
                NULLIF((data->>'num_likes')::text, '')::integer
            FROM latest_records
            WHERE rn = 1
            ON CONFLICT (account_id) 
            DO UPDATE SET
                --created_via = EXCLUDED.created_via,
                username = EXCLUDED.username,
                created_at = EXCLUDED.created_at,
                account_display_name = EXCLUDED.account_display_name,
                num_tweets = EXCLUDED.num_tweets,
                num_following = EXCLUDED.num_following,
                num_followers = EXCLUDED.num_followers,
                num_likes = EXCLUDED.num_likes
            RETURNING account_id
        )
        SELECT array_agg(account_id) INTO processed_ids FROM insertions;
        SELECT COUNT(*) INTO processed_count
        FROM unnest(processed_ids);
        -- Update inserted timestamp
        WITH processed_ids_table AS (
            SELECT unnest(processed_ids) as account_id
        )
        UPDATE temporary_data td
        SET inserted = CURRENT_TIMESTAMP
        FROM processed_ids_table pit
        WHERE td.type = 'import_account' 
        AND (td.data->>'account_id')::text = pit.account_id;
        -- Get error records
        SELECT array_agg((data->>'account_id')::text)
        INTO error_records
        FROM temporary_data
        WHERE type = 'import_account'
        AND (data->>'account_id')::text IS NOT NULL
        AND inserted IS NULL;
        RETURN QUERY SELECT processed_count, error_records;
  
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT -1, ARRAY[SQLERRM];
    END;
END;
$function$
;

CREATE OR REPLACE FUNCTION private.tes_process_media_records()
 RETURNS TABLE(processed integer, errors text[])
 LANGUAGE plpgsql
AS $function$
DECLARE
    processed_count INTEGER := 0;
    error_records TEXT[];
    processed_ids TEXT[];
BEGIN
    BEGIN
        WITH latest_records AS (
            SELECT DISTINCT ON ((data->>'media_id')::text)
                (data->>'media_id')::bigint as media_id,
                (data->>'tweet_id')::text as tweet_id,
                (data->>'media_url')::text as media_url,
                (data->>'media_type')::text as media_type,
                (data->>'width')::integer as width,
                (data->>'height')::integer as height
            FROM temporary_data 
            WHERE type = 'import_media'
            AND (data->>'media_id')::text IS NOT NULL
            AND inserted IS NULL
            ORDER BY (data->>'media_id')::text, timestamp DESC
        ),
        insertions AS (
            INSERT INTO public.tweet_media (
                media_id,
                tweet_id,
                media_url,
                media_type,
                width,
                height
            )
            SELECT 
                media_id,
                tweet_id,
                media_url,
                media_type,
                width,
                height
            FROM latest_records
            ON CONFLICT (media_id) 
            DO UPDATE SET
                tweet_id = EXCLUDED.tweet_id,
                media_url = EXCLUDED.media_url,
                media_type = EXCLUDED.media_type,
                width = EXCLUDED.width,
                height = EXCLUDED.height
            RETURNING media_id::text
        )
        SELECT array_agg(media_id) INTO processed_ids FROM insertions;
        SELECT COUNT(*) INTO processed_count
        FROM unnest(processed_ids);
        -- Update inserted timestamp for ALL related records
        UPDATE temporary_data td
        SET inserted = CURRENT_TIMESTAMP
        WHERE td.type = 'import_media'
        AND (td.data->>'media_id')::text = ANY(processed_ids);
        -- Get error records
        SELECT array_agg((data->>'media_id')::text)
        INTO error_records
        FROM temporary_data
        WHERE type = 'import_media'
        AND (data->>'media_id')::text IS NOT NULL
        AND inserted IS NULL;
        RETURN QUERY SELECT processed_count, error_records;
  
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT -1, ARRAY[SQLERRM];
    END;
END;
$function$
;

CREATE OR REPLACE FUNCTION private.tes_process_mention_records()
 RETURNS TABLE(processed integer, errors text[])
 LANGUAGE plpgsql
AS $function$
DECLARE
    processed_count INTEGER := 0;
    error_records TEXT[];
    processed_ids TEXT[];
BEGIN
    BEGIN
        -- First, insert or update the mentioned users
        WITH latest_records AS (
            SELECT *,
                ROW_NUMBER() OVER (
                    PARTITION BY (data->>'mentioned_user_id')::text 
                    ORDER BY timestamp DESC
                ) as rn
            FROM temporary_data 
            WHERE type = 'import_mention'
            AND (data->>'mentioned_user_id')::text IS NOT NULL
            AND inserted IS NULL
        ),
        user_insertions AS (
            INSERT INTO public.mentioned_users (
                user_id,
                name,
                screen_name,
                updated_at
            )
            SELECT 
                (data->>'mentioned_user_id')::text,
                (data->>'display_name')::text,
                (data->>'username')::text,
                CURRENT_TIMESTAMP
            FROM latest_records
            WHERE rn = 1
            ON CONFLICT (user_id) 
            DO UPDATE SET
                name = EXCLUDED.name,
                screen_name = EXCLUDED.screen_name,
                updated_at = CURRENT_TIMESTAMP
        ),
        mention_insertions AS (
            INSERT INTO public.user_mentions (
                mentioned_user_id,
                tweet_id
            )
            SELECT DISTINCT
                (data->>'mentioned_user_id')::text,
                (data->>'tweet_id')::text
            FROM latest_records
            WHERE rn = 1
            ON CONFLICT (mentioned_user_id, tweet_id) 
            DO UPDATE SET
                mentioned_user_id = EXCLUDED.mentioned_user_id
            RETURNING tweet_id
        )
        SELECT array_agg(tweet_id) INTO processed_ids FROM mention_insertions;
        SELECT COUNT(*) INTO processed_count
        FROM unnest(processed_ids);
        -- Update inserted timestamp
        WITH processed_ids_table AS (
            SELECT unnest(processed_ids) as tweet_id
        )
        UPDATE temporary_data td
        SET inserted = CURRENT_TIMESTAMP
        FROM processed_ids_table pit
        WHERE td.type = 'import_mention' 
        AND (td.data->>'tweet_id')::text = pit.tweet_id;
        -- Get error records
        SELECT array_agg((data->>'mentioned_user_id')::text || ':' || (data->>'tweet_id')::text)
        INTO error_records
        FROM temporary_data
        WHERE type = 'import_mention'
        AND (data->>'mentioned_user_id')::text IS NOT NULL
        AND inserted IS NULL;
        RETURN QUERY SELECT processed_count, error_records;
  
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT -1, ARRAY[SQLERRM];
    END;
END;
$function$
;

CREATE OR REPLACE FUNCTION private.tes_process_profile_records()
 RETURNS TABLE(processed integer, errors text[])
 LANGUAGE plpgsql
AS $function$
DECLARE
    processed_count INTEGER := 0;
    error_records TEXT[];
    processed_ids TEXT[];
BEGIN
    BEGIN
        WITH latest_records AS (
            SELECT *,
                ROW_NUMBER() OVER (
                    PARTITION BY (data->>'account_id')::text 
                    ORDER BY (data->>'created_at')::timestamp with time zone DESC
                ) as rn
            FROM temporary_data 
            WHERE type = 'import_profile' 
            AND (data->>'account_id')::text IS NOT NULL
            AND inserted IS NULL
        ),
        insertions AS (
            INSERT INTO public.all_profile (
                account_id,
                bio,
                website,
                location,
                avatar_media_url,
                header_media_url
            )
            SELECT 
                (data->>'account_id')::text,
                (data->>'bio')::text,
                (data->>'website')::text,
                (data->>'location')::text,
                (data->>'avatar_media_url')::text,
                (data->>'header_media_url')::text
            FROM latest_records
            WHERE rn = 1
            ON CONFLICT (account_id) 
            DO UPDATE SET
                bio = EXCLUDED.bio,
                website = EXCLUDED.website,
                location = EXCLUDED.location,
                avatar_media_url = EXCLUDED.avatar_media_url,
                header_media_url = EXCLUDED.header_media_url
            RETURNING account_id
        )
        SELECT array_agg(account_id) INTO processed_ids FROM insertions;
        SELECT COUNT(*) INTO processed_count
        FROM unnest(processed_ids);
        WITH processed_ids_table AS (
            SELECT unnest(processed_ids) as account_id
        )
        UPDATE temporary_data td
        SET inserted = CURRENT_TIMESTAMP
        FROM processed_ids_table pit
        WHERE td.type = 'import_profile' 
        AND (td.data->>'account_id')::text = pit.account_id;
        SELECT array_agg((data->>'account_id')::text)
        INTO error_records
        FROM temporary_data
        WHERE type = 'import_profile'
        AND (data->>'account_id')::text IS NOT NULL
        AND inserted IS NULL;
        RETURN QUERY SELECT processed_count, error_records;
  
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT -1, ARRAY[SQLERRM];
    END;
END;
$function$
;

CREATE OR REPLACE FUNCTION private.tes_process_tweet_records()
 RETURNS TABLE(processed integer, errors text[])
 LANGUAGE plpgsql
AS $function$
DECLARE
    processed_count INTEGER := 0;
    error_records TEXT[];
    processed_ids TEXT[];
BEGIN
    BEGIN
        WITH latest_records AS (
            SELECT *,
                ROW_NUMBER() OVER (
                    PARTITION BY (data->>'tweet_id')::text 
                    ORDER BY (data->>'created_at')::timestamp with time zone DESC
                ) as rn
            FROM temporary_data 
            WHERE type = 'import_tweet' 
            AND (data->>'tweet_id')::text IS NOT NULL
            AND inserted IS NULL
        ),
        insertions AS (
            INSERT INTO public.tweets (
                tweet_id,
                account_id,
                created_at,
                full_text,
                retweet_count,
                favorite_count,
                reply_to_tweet_id,
                reply_to_user_id,
                reply_to_username
            )
            SELECT 
                (data->>'tweet_id')::text,
                (data->>'account_id')::text,
                (data->>'created_at')::timestamp with time zone,
                (data->>'full_text')::text,
                COALESCE((data->>'retweet_count')::integer, 0),
                COALESCE((data->>'favorite_count')::integer, 0),
                NULLIF((data->>'reply_to_tweet_id')::text, ''),
                NULLIF((data->>'reply_to_user_id')::text, ''),
                NULLIF((data->>'reply_to_username')::text, '')
            FROM latest_records
            WHERE rn = 1
            ON CONFLICT (tweet_id) 
            DO UPDATE SET
                account_id = EXCLUDED.account_id,
                created_at = EXCLUDED.created_at,
                full_text = EXCLUDED.full_text,
                retweet_count = EXCLUDED.retweet_count,
                favorite_count = EXCLUDED.favorite_count,
                reply_to_tweet_id = EXCLUDED.reply_to_tweet_id,
                reply_to_user_id = EXCLUDED.reply_to_user_id,
                reply_to_username = EXCLUDED.reply_to_username
            RETURNING tweet_id
        )
        SELECT array_agg(tweet_id) INTO processed_ids FROM insertions;
        SELECT COUNT(*) INTO processed_count
        FROM unnest(processed_ids);
        WITH processed_ids_table AS (
            SELECT unnest(processed_ids) as tweet_id
        )
        UPDATE temporary_data td
        SET inserted = CURRENT_TIMESTAMP
        FROM processed_ids_table pit
        WHERE td.type = 'import_tweet' 
        AND (td.data->>'tweet_id')::text = pit.tweet_id;
        SELECT array_agg((data->>'tweet_id')::text)
        INTO error_records
        FROM temporary_data
        WHERE type = 'import_tweet'
        AND (data->>'tweet_id')::text IS NOT NULL
        AND inserted IS NULL;
        RETURN QUERY SELECT processed_count, error_records;
  
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT -1, ARRAY[SQLERRM];
    END;
END;
$function$
;

CREATE OR REPLACE FUNCTION private.tes_process_url_records()
 RETURNS TABLE(processed integer, errors text[])
 LANGUAGE plpgsql
AS $function$
DECLARE
    processed_count INTEGER := 0;
    error_records TEXT[];
    processed_ids TEXT[];
BEGIN
    BEGIN
        WITH latest_records AS (
            SELECT DISTINCT ON ((data->>'tweet_id')::text, (data->>'url')::text)
                data->>'url' as url,
                data->>'expanded_url' as expanded_url,
                data->>'display_url' as display_url,
                data->>'tweet_id' as tweet_id
            FROM temporary_data 
            WHERE type = 'import_url'
            AND (data->>'tweet_id')::text IS NOT NULL
            AND inserted IS NULL
            ORDER BY (data->>'tweet_id')::text, (data->>'url')::text, timestamp DESC
        ),
        insertions AS (
            INSERT INTO public.tweet_urls (
                url,
                expanded_url,
                display_url,
                tweet_id
            )
            SELECT 
                url,
                expanded_url,
                display_url,
                tweet_id
            FROM latest_records
            ON CONFLICT (tweet_id, url) 
            DO UPDATE SET
                expanded_url = EXCLUDED.expanded_url,
                display_url = EXCLUDED.display_url
            RETURNING tweet_id, url
        )
        SELECT array_agg(DISTINCT tweet_id) INTO processed_ids FROM insertions;
        SELECT COUNT(*) INTO processed_count
        FROM unnest(processed_ids);
        -- Update inserted timestamp for ALL related records
        UPDATE temporary_data td
        SET inserted = CURRENT_TIMESTAMP
        WHERE td.type = 'import_url'
        AND (td.data->>'tweet_id')::text || ':' || (td.data->>'url')::text IN (
            SELECT (data->>'tweet_id')::text || ':' || (data->>'url')::text
            FROM temporary_data
            WHERE type = 'import_url'
            AND (data->>'tweet_id')::text = ANY(processed_ids)
        );
        -- Get error records
        SELECT array_agg((data->>'tweet_id')::text || ':' || (data->>'url')::text)
        INTO error_records
        FROM temporary_data
        WHERE type = 'import_url'
        AND (data->>'tweet_id')::text IS NOT NULL
        AND inserted IS NULL;
        RETURN QUERY SELECT processed_count, error_records;
  
    EXCEPTION WHEN OTHERS THEN
        RETURN QUERY SELECT -1, ARRAY[SQLERRM];
    END;
END;
$function$
;


create extension if not exists "pg_net" with schema "public" version '0.8.0';

create extension if not exists "pgaudit" with schema "public" version '1.7';

drop trigger if exists "trigger_commit_temp_data" on "public"."archive_upload";

drop trigger if exists "queue_job_on_upload_complete" on "public"."archive_upload";

drop trigger if exists "queue_job_on_upload_delete" on "public"."archive_upload";

drop policy "Public read access" on "public"."conversations";

drop index if exists "public"."idx_quote_tweets_quoted_tweet_id";

drop function if exists "public"."apply_readonly_rls_policies"(schema_name text, table_name text);

drop function if exists "public"."delete_user_archive"(p_account_id text);

drop function if exists "public"."pg_search_tweets_with_trigram"(search_query text, p_account_id text);

drop function if exists "public"."trigger_commit_temp_data"();

drop view if exists "public"."enriched_tweets";

drop materialized view if exists "public"."quote_tweets";

alter table "public"."conversations" disable row level security;

CREATE INDEX idx_tweets_favorite_count ON public.tweets USING btree (favorite_count);

set check_function_bodies = off;

CREATE OR REPLACE FUNCTION public.delete_all_archives(p_account_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_schema_name TEXT := 'public';
    v_archive_upload_ids BIGINT[];
BEGIN
    SELECT ARRAY_AGG(id) INTO v_archive_upload_ids
    FROM public.archive_upload
    WHERE account_id = p_account_id;
    BEGIN
        -- Delete tweets and related data
        EXECUTE format('
            WITH tweets_to_delete AS (
                SELECT tweet_id FROM %I.tweets WHERE archive_upload_id = ANY($1) OR account_id = $2
            )
            DELETE FROM %I.tweet_media WHERE tweet_id IN (SELECT tweet_id FROM tweets_to_delete);
                WITH tweets_to_delete AS (
                    SELECT tweet_id FROM %I.tweets WHERE archive_upload_id = ANY($1) 
                )
            DELETE FROM %I.user_mentions WHERE tweet_id IN (SELECT tweet_id FROM tweets_to_delete);
            WITH tweets_to_delete AS (
                SELECT tweet_id FROM %I.tweets WHERE archive_upload_id = ANY($1) OR account_id = $2
            )
            DELETE FROM %I.tweet_urls WHERE tweet_id IN (SELECT tweet_id FROM tweets_to_delete);
            DELETE FROM %I.tweets WHERE archive_upload_id = ANY($1);
        ', v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name)
        USING v_archive_upload_ids, p_account_id;
        -- Delete other related data
        EXECUTE format('
            DELETE FROM %I.likes WHERE archive_upload_id = ANY($1);
            DELETE FROM %I.followers WHERE archive_upload_id = ANY($1);
            DELETE FROM %I.following WHERE archive_upload_id = ANY($1);
            DELETE FROM %I.all_profile WHERE archive_upload_id = ANY($1);
            DELETE FROM %I.tweet_media WHERE archive_upload_id = ANY($1);
            DELETE FROM %I.archive_upload WHERE id = ANY($1);
            DELETE FROM %I.all_account WHERE account_id = $2;
        ', v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name, v_schema_name)
        USING v_archive_upload_ids, p_account_id;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'Error deleting archives for account %: %', p_account_id, SQLERRM;
        RAISE;
    END;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.get_tweets_in_user_conversations(username_ text)
 RETURNS TABLE(conversation_id text, tweet_id text, created_at timestamp with time zone, full_text text)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT c.conversation_id, 
           t.tweet_id, 
           t.created_at, 
           t.full_text
    FROM tweets t
    JOIN conversations c ON t.tweet_id = c.tweet_id
    WHERE c.conversation_id IN (
        SELECT c.conversation_id
        FROM tweets t
        JOIN account a ON t.account_id = a.account_id
        JOIN conversations c ON t.tweet_id = c.tweet_id
        WHERE a.username = username_
    );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.commit_temp_data(p_suffix text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
    v_archive_upload_id BIGINT;
    v_account_id TEXT;
    v_archive_at TIMESTAMP WITH TIME ZONE;
    v_keep_private BOOLEAN;
    v_upload_likes BOOLEAN;
    v_start_date DATE;
    v_end_date DATE;
BEGIN
    IF auth.uid() IS NULL AND current_user != 'postgres' THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;
    RAISE NOTICE 'commit_temp_data called with suffix: %', p_suffix;
    -- 1. Insert account data first
    EXECUTE format('
        INSERT INTO public.all_account (
            created_via, username, account_id, created_at, account_display_name,
            num_tweets, num_following, num_followers, num_likes
        )
        SELECT 
            created_via, username, account_id, created_at, account_display_name,
            num_tweets, num_following, num_followers, num_likes
        FROM temp.account_%s
        ON CONFLICT (account_id) DO UPDATE SET
            username = EXCLUDED.username,
            account_display_name = EXCLUDED.account_display_name,
            created_via = EXCLUDED.created_via,
            created_at = EXCLUDED.created_at,
            num_tweets = EXCLUDED.num_tweets,
            num_following = EXCLUDED.num_following,
            num_followers = EXCLUDED.num_followers,
            num_likes = EXCLUDED.num_likes
        RETURNING account_id
    ', p_suffix) INTO v_account_id;
    -- 2. Get the latest archive upload data from temp.archive_upload
    EXECUTE format('
        SELECT archive_at, keep_private, upload_likes, start_date, end_date
        FROM temp.archive_upload_%s
        ORDER BY archive_at DESC
        LIMIT 1
    ', p_suffix) INTO v_archive_at, v_keep_private, v_upload_likes, v_start_date, v_end_date;
    -- 3. Insert or update archive_upload and get the ID
    INSERT INTO public.archive_upload (
        account_id, 
        archive_at, 
        created_at, 
        keep_private, 
        upload_likes, 
        start_date, 
        end_date,
        upload_phase
    )
    VALUES (
        v_account_id, 
        v_archive_at, 
        CURRENT_TIMESTAMP, 
        v_keep_private, 
        v_upload_likes, 
        v_start_date, 
        v_end_date,
        'uploading'
    )
    ON CONFLICT (account_id, archive_at)
    DO UPDATE SET
        account_id = EXCLUDED.account_id,
        created_at = CURRENT_TIMESTAMP,
        keep_private = EXCLUDED.keep_private,
        upload_likes = EXCLUDED.upload_likes,
        start_date = EXCLUDED.start_date,
        end_date = EXCLUDED.end_date,
        upload_phase = 'uploading'
    RETURNING id INTO v_archive_upload_id;
    -- Insert profile data
    EXECUTE format('
        INSERT INTO public.all_profile (bio, website, location, avatar_media_url, header_media_url, account_id, archive_upload_id)
        SELECT p.bio, p.website, p.location, p.avatar_media_url, p.header_media_url, p.account_id, $1
        FROM temp.profile_%s p
        ON CONFLICT (account_id) DO UPDATE SET
            bio = EXCLUDED.bio,
            website = EXCLUDED.website,
            location = EXCLUDED.location,
            avatar_media_url = EXCLUDED.avatar_media_url,
            header_media_url = EXCLUDED.header_media_url,
            archive_upload_id = EXCLUDED.archive_upload_id
    ', p_suffix) USING v_archive_upload_id;
    -- Insert tweets data
    EXECUTE format('
        INSERT INTO public.tweets (tweet_id, account_id, created_at, full_text, retweet_count, favorite_count, reply_to_tweet_id, reply_to_user_id, reply_to_username, archive_upload_id)
        SELECT t.tweet_id, t.account_id, t.created_at, t.full_text, t.retweet_count, t.favorite_count, t.reply_to_tweet_id, t.reply_to_user_id, t.reply_to_username, $1
        FROM temp.tweets_%s t
        ON CONFLICT (tweet_id) DO UPDATE SET
            full_text = EXCLUDED.full_text,
            retweet_count = EXCLUDED.retweet_count,
            favorite_count = EXCLUDED.favorite_count,
            reply_to_tweet_id = EXCLUDED.reply_to_tweet_id,
            reply_to_user_id = EXCLUDED.reply_to_user_id,
            reply_to_username = EXCLUDED.reply_to_username,
            archive_upload_id = EXCLUDED.archive_upload_id
    ', p_suffix) USING v_archive_upload_id;
    -- Insert tweet_media data
    EXECUTE format('
        INSERT INTO public.tweet_media (media_id, tweet_id, media_url, media_type, width, height, archive_upload_id)
        SELECT tm.media_id, tm.tweet_id, tm.media_url, tm.media_type, tm.width, tm.height, $1
        FROM temp.tweet_media_%s tm
        ON CONFLICT (media_id) DO UPDATE SET
            media_url = EXCLUDED.media_url,
            media_type = EXCLUDED.media_type,
            width = EXCLUDED.width,
            height = EXCLUDED.height,
            archive_upload_id = EXCLUDED.archive_upload_id
    ', p_suffix) USING v_archive_upload_id;
    -- Insert mentioned_users data
    EXECUTE format('
        INSERT INTO public.mentioned_users (user_id, name, screen_name, updated_at)
        SELECT user_id, name, screen_name, updated_at
        FROM temp.mentioned_users_%s
        ON CONFLICT (user_id) DO UPDATE SET
            name = EXCLUDED.name,
            screen_name = EXCLUDED.screen_name,
            updated_at = EXCLUDED.updated_at
    ', p_suffix);
    -- Insert user_mentions data
    EXECUTE format('
        INSERT INTO public.user_mentions (mentioned_user_id, tweet_id)
        SELECT um.mentioned_user_id, um.tweet_id
        FROM temp.user_mentions_%s um
        JOIN public.mentioned_users mu ON um.mentioned_user_id = mu.user_id
        JOIN public.tweets t ON um.tweet_id = t.tweet_id
        ON CONFLICT (mentioned_user_id, tweet_id) DO NOTHING
    ', p_suffix);
    -- Insert tweet_urls data
    EXECUTE format('
        INSERT INTO public.tweet_urls (url, expanded_url, display_url, tweet_id)
        SELECT tu.url, tu.expanded_url, tu.display_url, tu.tweet_id
        FROM temp.tweet_urls_%s tu
        JOIN public.tweets t ON tu.tweet_id = t.tweet_id
        ON CONFLICT (tweet_id, url) DO NOTHING
    ', p_suffix);
    -- Insert followers data
    EXECUTE format('
        INSERT INTO public.followers (account_id, follower_account_id, archive_upload_id)
        SELECT f.account_id, f.follower_account_id, $1
        FROM temp.followers_%s f
        ON CONFLICT (account_id, follower_account_id) DO UPDATE SET
            archive_upload_id = EXCLUDED.archive_upload_id
    ', p_suffix) USING v_archive_upload_id;
    -- Insert following data
    EXECUTE format('
        INSERT INTO public.following (account_id, following_account_id, archive_upload_id)
        SELECT f.account_id, f.following_account_id, $1
        FROM temp.following_%s f
        ON CONFLICT (account_id, following_account_id) DO UPDATE SET
            archive_upload_id = EXCLUDED.archive_upload_id
    ', p_suffix) USING v_archive_upload_id;
    -- Insert liked_tweets data
    EXECUTE format('
        INSERT INTO public.liked_tweets (tweet_id, full_text)
        SELECT lt.tweet_id, lt.full_text
        FROM temp.liked_tweets_%s lt
        ON CONFLICT (tweet_id) DO NOTHING
    ', p_suffix);
    -- Insert likes data
    EXECUTE format('
        INSERT INTO public.likes (account_id, liked_tweet_id, archive_upload_id)
          SELECT l.account_id, l.liked_tweet_id, $1
        FROM temp.likes_%s l
        ON CONFLICT (account_id, liked_tweet_id) DO UPDATE SET
            archive_upload_id = EXCLUDED.archive_upload_id
    ', p_suffix) USING v_archive_upload_id;
    -- Drop temporary tables after committing
    PERFORM public.drop_temp_tables(p_suffix);
    -- Update upload_phase to 'completed' after successful execution
    UPDATE public.archive_upload
    SET upload_phase = 'completed'
    WHERE id = v_archive_upload_id;
EXCEPTION
    WHEN OTHERS THEN
        -- Update upload_phase to 'failed' if an error occurs
        UPDATE public.archive_upload
        SET upload_phase = 'failed'
        WHERE id = v_archive_upload_id;
        RAISE;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.create_temp_tables(p_suffix text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
-- Check if the user is authenticated or is the postgres role
IF auth.uid() IS NULL AND current_user NOT IN ('postgres', 'service_role') THEN
RAISE EXCEPTION 'Not authenticated';
END IF;
IF p_suffix != ((SELECT auth.jwt()) -> 'app_metadata' ->> 'provider_id') AND current_user != 'postgres' THEN
RAISE EXCEPTION 'Not authorized to process this archive';
END IF;
-- Drop the temporary tables if they exist
PERFORM public.drop_temp_tables(p_suffix);
-- Create new tables
EXECUTE format('CREATE TABLE temp.archive_upload_%s (LIKE public.archive_upload INCLUDING ALL)', p_suffix);
EXECUTE format('CREATE TABLE temp.account_%s (LIKE public.account INCLUDING ALL)', p_suffix);
EXECUTE format('CREATE TABLE temp.profile_%s (LIKE public.profile INCLUDING ALL)', p_suffix);
EXECUTE format('CREATE TABLE temp.tweets_%s (LIKE public.tweets INCLUDING ALL)', p_suffix);
EXECUTE format('CREATE TABLE temp.mentioned_users_%s (LIKE public.mentioned_users INCLUDING ALL)', p_suffix);
EXECUTE format('CREATE TABLE temp.user_mentions_%s (LIKE public.user_mentions INCLUDING ALL)', p_suffix);
EXECUTE format('CREATE TABLE temp.tweet_urls_%s (LIKE public.tweet_urls INCLUDING ALL)', p_suffix);
EXECUTE format('CREATE TABLE temp.tweet_media_%s (LIKE public.tweet_media INCLUDING ALL)', p_suffix);
EXECUTE format('CREATE TABLE temp.followers_%s (LIKE public.followers INCLUDING ALL)', p_suffix);
EXECUTE format('CREATE TABLE temp.following_%s (LIKE public.following INCLUDING ALL)', p_suffix);
EXECUTE format('CREATE TABLE temp.liked_tweets_%s (LIKE public.liked_tweets INCLUDING ALL)', p_suffix);
EXECUTE format('CREATE TABLE temp.likes_%s (LIKE public.likes INCLUDING ALL)', p_suffix);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.drop_temp_tables(p_suffix text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
IF auth.uid() IS NULL AND current_user NOT IN ('postgres', 'service_role') THEN
RAISE EXCEPTION 'Not authenticated';
END IF;
EXECUTE format('DROP TABLE IF EXISTS temp.account_%s', p_suffix);
EXECUTE format('DROP TABLE IF EXISTS temp.archive_upload_%s', p_suffix);
EXECUTE format('DROP TABLE IF EXISTS temp.profile_%s', p_suffix);
EXECUTE format('DROP TABLE IF EXISTS temp.tweets_%s', p_suffix);
EXECUTE format('DROP TABLE IF EXISTS temp.mentioned_users_%s', p_suffix);
EXECUTE format('DROP TABLE IF EXISTS temp.user_mentions_%s', p_suffix);
EXECUTE format('DROP TABLE IF EXISTS temp.tweet_urls_%s', p_suffix);
EXECUTE format('DROP TABLE IF EXISTS temp.tweet_media_%s', p_suffix);
EXECUTE format('DROP TABLE IF EXISTS temp.followers_%s', p_suffix);
EXECUTE format('DROP TABLE IF EXISTS temp.following_%s', p_suffix);
EXECUTE format('DROP TABLE IF EXISTS temp.liked_tweets_%s', p_suffix);
EXECUTE format('DROP TABLE IF EXISTS temp.likes_%s', p_suffix);
END;
$function$
;

CREATE OR REPLACE FUNCTION public.insert_temp_account(p_account jsonb, p_suffix text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
BEGIN
IF auth.uid() IS NULL AND current_user NOT IN ('postgres', 'service_role') THEN
RAISE EXCEPTION 'Not authenticated';
END IF;

EXECUTE format('
INSERT INTO temp.account_%s (
    account_id, created_via, username, created_at, account_display_name,
    num_tweets, num_following, num_followers, num_likes
)
SELECT
$1->>''accountId'',
$1->>''createdVia'',
$1->>''username'',
($1->>''createdAt'')::TIMESTAMP WITH TIME ZONE,
$1->>''accountDisplayName'',
COALESCE(($1->>''num_tweets'')::INTEGER, 0),
COALESCE(($1->>''num_following'')::INTEGER, 0),
COALESCE(($1->>''num_followers'')::INTEGER, 0),
COALESCE(($1->>''num_likes'')::INTEGER, 0)
', p_suffix)
USING p_account;
END;
$function$
;

create or replace view "public"."quote_tweets" as  SELECT t.tweet_id,
    "substring"(tu.expanded_url, 'status/([0-9]+)'::text) AS quoted_tweet_id,
    "substring"(tu.expanded_url, 'https?://(?:www\.)?twitter\.com/([^/]+)/status/'::text) AS quoted_tweet_username
   FROM (tweet_urls tu
     JOIN tweets t ON ((tu.tweet_id = t.tweet_id)))
  WHERE ((tu.expanded_url ~~ 'https://twitter.com/%/status/%'::text) OR (tu.expanded_url ~~ 'https://x.com/%/status/%'::text));


CREATE OR REPLACE FUNCTION public.sync_meta_data()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    NEW.raw_app_meta_data = jsonb_set(
        jsonb_set(
            COALESCE(NEW.raw_app_meta_data::jsonb, '{}'::jsonb),
            '{user_name}',
            NEW.raw_user_meta_data::jsonb->'user_name'
        ),
        '{provider_id}',
        NEW.raw_user_meta_data::jsonb->'provider_id'
    );
    RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.tes_get_followers(user_id text)
 RETURNS TABLE(account_id text, username text)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT 
        f1.follower_account_id AS account_id,
        mu.screen_name AS username
    FROM public.followers f1
    LEFT JOIN mentioned_users mu ON mu.user_id = f1.follower_account_id
    WHERE f1.account_id = $1 and mu.screen_name is not null;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.tes_get_followings(user_id text)
 RETURNS TABLE(account_id text, username text)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT 
        f2.following_account_id AS account_id,
        mu.screen_name AS username
    FROM public.following f2
    LEFT JOIN mentioned_users mu ON mu.user_id = f2.following_account_id
    WHERE f2.account_id = $1 and mu.screen_name is not null; 
END;
$function$
;

CREATE OR REPLACE FUNCTION public.tes_get_moots(user_id text)
 RETURNS TABLE(account_id text, username text)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT 
    f1.follower_account_id as account_id,
	mu.screen_name as username
    FROM public.followers f1
    INNER JOIN public.following f2 
        ON f1.account_id = f2.account_id 
        AND f1.follower_account_id = f2.following_account_id
	left join mentioned_users mu on mu.user_id = f1.follower_account_id
    where f1.account_id = $1;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.tes_get_tweet_counts_by_date(p_account_id text)
 RETURNS TABLE(tweet_date date, tweet_count bigint)
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN QUERY
    SELECT 
        DATE(created_at) AS tweet_date,
        COUNT(*) AS tweet_count
    FROM 
        public.tweets
    WHERE 
        account_id = p_account_id
    GROUP BY 
        DATE(created_at)
    ORDER BY 
        tweet_date;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.tes_get_tweets_on_this_day(p_limit integer DEFAULT NULL::integer, p_account_id text DEFAULT NULL::text)
 RETURNS TABLE(tweet_id text, account_id text, created_at timestamp with time zone, full_text text, retweet_count integer, favorite_count integer, reply_to_tweet_id text, reply_to_user_id text, reply_to_username text, username text, account_display_name text, avatar_media_url text)
 LANGUAGE plpgsql
AS $function$
DECLARE
    current_month INTEGER;
    current_day INTEGER;
BEGIN
    -- Get the current month and day
    SELECT EXTRACT(MONTH FROM CURRENT_DATE), EXTRACT(DAY FROM CURRENT_DATE)
    INTO current_month, current_day;

    RETURN QUERY
    SELECT 
        t.tweet_id, t.account_id, t.created_at, t.full_text, t.retweet_count,
        t.favorite_count, t.reply_to_tweet_id, t.reply_to_user_id, t.reply_to_username,
		a.username,a.account_display_name,p.avatar_media_url
    FROM 
        public.tweets t
		inner join account a on t.account_id = a.account_id
		inner join profile p on t.account_id = p.account_id
    WHERE 
        EXTRACT(MONTH FROM t.created_at AT TIME ZONE 'UTC') = current_month
        AND EXTRACT(DAY FROM t.created_at AT TIME ZONE 'UTC') = current_day
        AND EXTRACT(YEAR FROM t.created_at AT TIME ZONE 'UTC') < EXTRACT(YEAR FROM CURRENT_DATE)
        AND (p_account_id IS NULL OR t.account_id = p_account_id)
    ORDER BY 
        t.favorite_count DESC,t.retweet_count DESC
    LIMIT p_limit;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.tes_search_liked_tweets(search_query text, from_user text DEFAULT NULL::text, to_user text DEFAULT NULL::text, since_date date DEFAULT NULL::date, until_date date DEFAULT NULL::date, min_likes integer DEFAULT 0, min_retweets integer DEFAULT 0, max_likes integer DEFAULT 100000000, max_retweets integer DEFAULT 100000000, limit_ integer DEFAULT 50, auth_account_id text DEFAULT NULL::text)
 RETURNS TABLE(tweet_id text, account_id text, created_at timestamp with time zone, full_text text, retweet_count integer, favorite_count integer, reply_to_tweet_id text, avatar_media_url text, archive_upload_id bigint, username text, account_display_name text)
 LANGUAGE plpgsql
AS $function$
DECLARE
  from_account_id TEXT;
  to_account_id TEXT;
BEGIN
  -- Get account_id for from_user
  IF from_user IS NOT NULL THEN
    SELECT a.account_id INTO from_account_id
    FROM account as a
    WHERE LOWER(a.username) = LOWER(from_user);
    
    -- Return empty if from_user not found
    IF from_account_id IS NULL THEN
      RETURN;
    END IF;
  END IF;

  -- Get account_id for to_user
  IF to_user IS NOT NULL THEN
    SELECT a.account_id INTO to_account_id
    FROM account as a
    WHERE LOWER(a.username) = LOWER(to_user);
    
    -- Return empty if to_user not found
    IF to_account_id IS NULL THEN
      RETURN;
    END IF;
  END IF;

  RETURN QUERY
  WITH combined_tweets AS (
    SELECT 
      COALESCE(t.tweet_id,lt.tweet_id) as tweet_id,
      t.account_id,
      t.created_at,
      COALESCE(t.full_text, lt.full_text) as full_text,
      t.retweet_count,
      t.favorite_count,
      t.reply_to_user_id,
      t.reply_to_tweet_id
    FROM (
      SELECT lt.tweet_id, lt.full_text 
      FROM liked_tweets lt
      left JOIN likes l ON lt.tweet_id = l.liked_tweet_id 
      WHERE l.account_id = auth_account_id 

    ) lt
    LEFT JOIN tweets t ON lt.tweet_id = t.tweet_id

  ),
  matching_tweets AS (
    SELECT ct.tweet_id,ct.full_text
    FROM combined_tweets ct
    WHERE (search_query = '' OR to_tsvector('english', ct.full_text) @@ websearch_to_tsquery('english', search_query))
      AND (from_account_id IS NULL OR ct.account_id = from_account_id)
      AND (to_account_id IS NULL OR ct.reply_to_user_id = to_account_id)
      AND (since_date IS NULL OR ct.created_at >= since_date OR ct.created_at IS NULL)
      AND (until_date IS NULL OR ct.created_at <= until_date OR ct.created_at IS NULL)
      AND (min_likes IS NULL OR ct.favorite_count >= min_likes OR ct.favorite_count IS NULL)
      AND (max_likes IS NULL OR ct.favorite_count <= max_likes OR ct.favorite_count IS NULL)
      AND (min_retweets IS NULL OR ct.retweet_count >= min_retweets OR ct.retweet_count IS NULL)
      AND (max_retweets IS NULL OR ct.retweet_count <= max_retweets OR ct.retweet_count IS NULL)
    ORDER BY COALESCE(ct.created_at, '2099-12-31'::timestamp) DESC
    LIMIT limit_
  )
  SELECT 
    COALESCE (mt.tweet_id,t.tweet_id), 
    t.account_id, 
    t.created_at, 
    COALESCE (mt.full_text,t.full_text), 
    t.retweet_count, 
    t.favorite_count,
    t.reply_to_tweet_id,
    p.avatar_media_url,
    p.archive_upload_id,
    a.username,
    a.account_display_name
  FROM matching_tweets mt
  LEFT JOIN tweets t ON mt.tweet_id = t.tweet_id
  LEFT JOIN account a ON t.account_id = a.account_id
  LEFT JOIN LATERAL (
    SELECT COALESCE(p.avatar_media_url,'none.com') as avatar_media_url, p.archive_upload_id
    FROM profile as p
    WHERE p.account_id = t.account_id
    ORDER BY p.archive_upload_id DESC
    LIMIT 1
  ) p ON true
  ORDER BY t.created_at DESC;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.update_foreign_keys(old_table_name text, new_table_name text, schema_name text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
    constraint_record record;
BEGIN
    -- Begin transaction
    BEGIN
        FOR constraint_record IN 
            SELECT 
                tc.table_name,
                tc.constraint_name,
                kcu.column_name
            FROM information_schema.table_constraints tc
            JOIN information_schema.key_column_usage kcu
                ON tc.constraint_name = kcu.constraint_name
                AND tc.table_schema = kcu.table_schema
            JOIN information_schema.constraint_column_usage ccu
                ON ccu.constraint_name = tc.constraint_name
            WHERE tc.constraint_type = 'FOREIGN KEY'
                AND ccu.table_name = old_table_name
                AND tc.table_schema = schema_name
                --AND tc.table_name != 'archive_upload'  -- Skip archive_upload table
        LOOP
            -- Drop old constraint
            EXECUTE format('ALTER TABLE %I.%I DROP CONSTRAINT %I',
                schema_name,
                constraint_record.table_name,
                constraint_record.constraint_name
            );
            -- Add new constraint without validation
            EXECUTE format(
                'ALTER TABLE %I.%I ADD CONSTRAINT %I FOREIGN KEY (%I) REFERENCES %I.%I(%I) NOT VALID',
                schema_name,
                constraint_record.table_name,
                constraint_record.constraint_name,
                constraint_record.column_name,
                schema_name,
                new_table_name,
                constraint_record.column_name
            );
            -- Validate the constraint
            EXECUTE format(
                'ALTER TABLE %I.%I VALIDATE CONSTRAINT %I',
                schema_name,
                constraint_record.table_name,
                constraint_record.constraint_name
            );
            RAISE NOTICE 'Updated foreign key for table: %.%', schema_name, constraint_record.table_name;
        END LOOP;
    EXCEPTION WHEN OTHERS THEN
        -- If there's an error, rollback everything
        RAISE NOTICE 'Error occurred: %', SQLERRM;
        RAISE;
    END;
END;
$function$
;

CREATE OR REPLACE FUNCTION public.update_updated_at_column()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
   BEGIN
       NEW.updated_at = CURRENT_TIMESTAMP;
       RETURN NEW;
   END;
   $function$
;

create or replace view "public"."tweets_enriched" as  SELECT t.tweet_id,
    t.account_id,
    a.username,
    a.account_display_name,
    t.created_at,
    t.full_text,
    t.retweet_count,
    t.favorite_count,
    t.reply_to_tweet_id,
    t.reply_to_user_id,
    t.reply_to_username,
    qt.quoted_tweet_id,
    c.conversation_id,
    ( SELECT p.avatar_media_url
           FROM profile p
          WHERE (p.account_id = t.account_id)
          ORDER BY p.archive_upload_id DESC
         LIMIT 1) AS avatar_media_url,
    t.archive_upload_id
   FROM (((tweets t
     JOIN account a ON ((t.account_id = a.account_id)))
     LEFT JOIN conversations c ON ((t.tweet_id = c.tweet_id)))
     LEFT JOIN quote_tweets qt ON ((t.tweet_id = qt.tweet_id)));


create or replace view "public"."enriched_tweets" as  SELECT t.tweet_id,
    t.account_id,
    a.username,
    a.account_display_name,
    t.created_at,
    t.full_text,
    t.retweet_count,
    t.favorite_count,
    t.reply_to_tweet_id,
    t.reply_to_user_id,
    t.reply_to_username,
    qt.quoted_tweet_id,
    c.conversation_id,
    ( SELECT p.avatar_media_url
           FROM profile p
          WHERE (p.account_id = t.account_id)
          ORDER BY p.archive_upload_id DESC
         LIMIT 1) AS avatar_media_url,
    t.archive_upload_id
   FROM (((tweets t
     JOIN all_account a ON ((t.account_id = a.account_id)))
     LEFT JOIN conversations c ON ((t.tweet_id = c.tweet_id)))
     LEFT JOIN quote_tweets qt ON ((t.tweet_id = qt.tweet_id)));


grant select on table "public"."all_account" to "readclient";

grant select on table "public"."all_profile" to "readclient";

grant select on table "public"."archive_upload" to "readclient";

grant select on table "public"."conversations" to "readclient";

grant select on table "public"."followers" to "readclient";

grant select on table "public"."following" to "readclient";

grant select on table "public"."liked_tweets" to "readclient";

grant select on table "public"."likes" to "readclient";

grant select on table "public"."mentioned_users" to "readclient";

grant select on table "public"."temporary_data" to "readclient";

grant select on table "public"."tweet_media" to "readclient";

grant select on table "public"."tweet_urls" to "readclient";

grant select on table "public"."tweets" to "readclient";

grant select on table "public"."user_mentions" to "readclient";

CREATE TRIGGER queue_update_conversation_ids_on_upload_complete AFTER UPDATE OF upload_phase ON public.archive_upload FOR EACH ROW WHEN ((new.upload_phase = 'completed'::upload_phase_enum)) EXECUTE FUNCTION private.queue_update_conversation_ids();

CREATE TRIGGER queue_job_on_upload_complete AFTER UPDATE OF upload_phase ON public.archive_upload FOR EACH ROW WHEN ((new.upload_phase = 'completed'::upload_phase_enum)) EXECUTE FUNCTION private.queue_refresh_activity_summary();

CREATE TRIGGER queue_job_on_upload_delete AFTER DELETE ON public.archive_upload FOR EACH ROW EXECUTE FUNCTION private.queue_refresh_activity_summary();


revoke delete on table "temp"."account_1038586640" from "anon";

revoke insert on table "temp"."account_1038586640" from "anon";

revoke references on table "temp"."account_1038586640" from "anon";

revoke select on table "temp"."account_1038586640" from "anon";

revoke trigger on table "temp"."account_1038586640" from "anon";

revoke truncate on table "temp"."account_1038586640" from "anon";

revoke update on table "temp"."account_1038586640" from "anon";

revoke delete on table "temp"."account_1038586640" from "authenticated";

revoke insert on table "temp"."account_1038586640" from "authenticated";

revoke references on table "temp"."account_1038586640" from "authenticated";

revoke select on table "temp"."account_1038586640" from "authenticated";

revoke trigger on table "temp"."account_1038586640" from "authenticated";

revoke truncate on table "temp"."account_1038586640" from "authenticated";

revoke update on table "temp"."account_1038586640" from "authenticated";

revoke delete on table "temp"."account_1038586640" from "service_role";

revoke insert on table "temp"."account_1038586640" from "service_role";

revoke references on table "temp"."account_1038586640" from "service_role";

revoke select on table "temp"."account_1038586640" from "service_role";

revoke trigger on table "temp"."account_1038586640" from "service_role";

revoke truncate on table "temp"."account_1038586640" from "service_role";

revoke update on table "temp"."account_1038586640" from "service_role";

revoke delete on table "temp"."account_1378862677871751174" from "anon";

revoke insert on table "temp"."account_1378862677871751174" from "anon";

revoke references on table "temp"."account_1378862677871751174" from "anon";

revoke select on table "temp"."account_1378862677871751174" from "anon";

revoke trigger on table "temp"."account_1378862677871751174" from "anon";

revoke truncate on table "temp"."account_1378862677871751174" from "anon";

revoke update on table "temp"."account_1378862677871751174" from "anon";

revoke delete on table "temp"."account_1378862677871751174" from "authenticated";

revoke insert on table "temp"."account_1378862677871751174" from "authenticated";

revoke references on table "temp"."account_1378862677871751174" from "authenticated";

revoke select on table "temp"."account_1378862677871751174" from "authenticated";

revoke trigger on table "temp"."account_1378862677871751174" from "authenticated";

revoke truncate on table "temp"."account_1378862677871751174" from "authenticated";

revoke update on table "temp"."account_1378862677871751174" from "authenticated";

revoke delete on table "temp"."account_1378862677871751174" from "service_role";

revoke insert on table "temp"."account_1378862677871751174" from "service_role";

revoke references on table "temp"."account_1378862677871751174" from "service_role";

revoke select on table "temp"."account_1378862677871751174" from "service_role";

revoke trigger on table "temp"."account_1378862677871751174" from "service_role";

revoke truncate on table "temp"."account_1378862677871751174" from "service_role";

revoke update on table "temp"."account_1378862677871751174" from "service_role";

revoke delete on table "temp"."account_316970336" from "anon";

revoke insert on table "temp"."account_316970336" from "anon";

revoke references on table "temp"."account_316970336" from "anon";

revoke select on table "temp"."account_316970336" from "anon";

revoke trigger on table "temp"."account_316970336" from "anon";

revoke truncate on table "temp"."account_316970336" from "anon";

revoke update on table "temp"."account_316970336" from "anon";

revoke delete on table "temp"."account_316970336" from "authenticated";

revoke insert on table "temp"."account_316970336" from "authenticated";

revoke references on table "temp"."account_316970336" from "authenticated";

revoke select on table "temp"."account_316970336" from "authenticated";

revoke trigger on table "temp"."account_316970336" from "authenticated";

revoke truncate on table "temp"."account_316970336" from "authenticated";

revoke update on table "temp"."account_316970336" from "authenticated";

revoke delete on table "temp"."account_316970336" from "service_role";

revoke insert on table "temp"."account_316970336" from "service_role";

revoke references on table "temp"."account_316970336" from "service_role";

revoke select on table "temp"."account_316970336" from "service_role";

revoke trigger on table "temp"."account_316970336" from "service_role";

revoke truncate on table "temp"."account_316970336" from "service_role";

revoke update on table "temp"."account_316970336" from "service_role";

revoke delete on table "temp"."archive_upload_1038586640" from "anon";

revoke insert on table "temp"."archive_upload_1038586640" from "anon";

revoke references on table "temp"."archive_upload_1038586640" from "anon";

revoke select on table "temp"."archive_upload_1038586640" from "anon";

revoke trigger on table "temp"."archive_upload_1038586640" from "anon";

revoke truncate on table "temp"."archive_upload_1038586640" from "anon";

revoke update on table "temp"."archive_upload_1038586640" from "anon";

revoke delete on table "temp"."archive_upload_1038586640" from "authenticated";

revoke insert on table "temp"."archive_upload_1038586640" from "authenticated";

revoke references on table "temp"."archive_upload_1038586640" from "authenticated";

revoke select on table "temp"."archive_upload_1038586640" from "authenticated";

revoke trigger on table "temp"."archive_upload_1038586640" from "authenticated";

revoke truncate on table "temp"."archive_upload_1038586640" from "authenticated";

revoke update on table "temp"."archive_upload_1038586640" from "authenticated";

revoke delete on table "temp"."archive_upload_1038586640" from "service_role";

revoke insert on table "temp"."archive_upload_1038586640" from "service_role";

revoke references on table "temp"."archive_upload_1038586640" from "service_role";

revoke select on table "temp"."archive_upload_1038586640" from "service_role";

revoke trigger on table "temp"."archive_upload_1038586640" from "service_role";

revoke truncate on table "temp"."archive_upload_1038586640" from "service_role";

revoke update on table "temp"."archive_upload_1038586640" from "service_role";

revoke delete on table "temp"."archive_upload_1378862677871751174" from "anon";

revoke insert on table "temp"."archive_upload_1378862677871751174" from "anon";

revoke references on table "temp"."archive_upload_1378862677871751174" from "anon";

revoke select on table "temp"."archive_upload_1378862677871751174" from "anon";

revoke trigger on table "temp"."archive_upload_1378862677871751174" from "anon";

revoke truncate on table "temp"."archive_upload_1378862677871751174" from "anon";

revoke update on table "temp"."archive_upload_1378862677871751174" from "anon";

revoke delete on table "temp"."archive_upload_1378862677871751174" from "authenticated";

revoke insert on table "temp"."archive_upload_1378862677871751174" from "authenticated";

revoke references on table "temp"."archive_upload_1378862677871751174" from "authenticated";

revoke select on table "temp"."archive_upload_1378862677871751174" from "authenticated";

revoke trigger on table "temp"."archive_upload_1378862677871751174" from "authenticated";

revoke truncate on table "temp"."archive_upload_1378862677871751174" from "authenticated";

revoke update on table "temp"."archive_upload_1378862677871751174" from "authenticated";

revoke delete on table "temp"."archive_upload_1378862677871751174" from "service_role";

revoke insert on table "temp"."archive_upload_1378862677871751174" from "service_role";

revoke references on table "temp"."archive_upload_1378862677871751174" from "service_role";

revoke select on table "temp"."archive_upload_1378862677871751174" from "service_role";

revoke trigger on table "temp"."archive_upload_1378862677871751174" from "service_role";

revoke truncate on table "temp"."archive_upload_1378862677871751174" from "service_role";

revoke update on table "temp"."archive_upload_1378862677871751174" from "service_role";

revoke delete on table "temp"."archive_upload_316970336" from "anon";

revoke insert on table "temp"."archive_upload_316970336" from "anon";

revoke references on table "temp"."archive_upload_316970336" from "anon";

revoke select on table "temp"."archive_upload_316970336" from "anon";

revoke trigger on table "temp"."archive_upload_316970336" from "anon";

revoke truncate on table "temp"."archive_upload_316970336" from "anon";

revoke update on table "temp"."archive_upload_316970336" from "anon";

revoke delete on table "temp"."archive_upload_316970336" from "authenticated";

revoke insert on table "temp"."archive_upload_316970336" from "authenticated";

revoke references on table "temp"."archive_upload_316970336" from "authenticated";

revoke select on table "temp"."archive_upload_316970336" from "authenticated";

revoke trigger on table "temp"."archive_upload_316970336" from "authenticated";

revoke truncate on table "temp"."archive_upload_316970336" from "authenticated";

revoke update on table "temp"."archive_upload_316970336" from "authenticated";

revoke delete on table "temp"."archive_upload_316970336" from "service_role";

revoke insert on table "temp"."archive_upload_316970336" from "service_role";

revoke references on table "temp"."archive_upload_316970336" from "service_role";

revoke select on table "temp"."archive_upload_316970336" from "service_role";

revoke trigger on table "temp"."archive_upload_316970336" from "service_role";

revoke truncate on table "temp"."archive_upload_316970336" from "service_role";

revoke update on table "temp"."archive_upload_316970336" from "service_role";

revoke delete on table "temp"."followers_1038586640" from "anon";

revoke insert on table "temp"."followers_1038586640" from "anon";

revoke references on table "temp"."followers_1038586640" from "anon";

revoke select on table "temp"."followers_1038586640" from "anon";

revoke trigger on table "temp"."followers_1038586640" from "anon";

revoke truncate on table "temp"."followers_1038586640" from "anon";

revoke update on table "temp"."followers_1038586640" from "anon";

revoke delete on table "temp"."followers_1038586640" from "authenticated";

revoke insert on table "temp"."followers_1038586640" from "authenticated";

revoke references on table "temp"."followers_1038586640" from "authenticated";

revoke select on table "temp"."followers_1038586640" from "authenticated";

revoke trigger on table "temp"."followers_1038586640" from "authenticated";

revoke truncate on table "temp"."followers_1038586640" from "authenticated";

revoke update on table "temp"."followers_1038586640" from "authenticated";

revoke delete on table "temp"."followers_1038586640" from "service_role";

revoke insert on table "temp"."followers_1038586640" from "service_role";

revoke references on table "temp"."followers_1038586640" from "service_role";

revoke select on table "temp"."followers_1038586640" from "service_role";

revoke trigger on table "temp"."followers_1038586640" from "service_role";

revoke truncate on table "temp"."followers_1038586640" from "service_role";

revoke update on table "temp"."followers_1038586640" from "service_role";

revoke delete on table "temp"."followers_1211134623285047297" from "anon";

revoke insert on table "temp"."followers_1211134623285047297" from "anon";

revoke references on table "temp"."followers_1211134623285047297" from "anon";

revoke select on table "temp"."followers_1211134623285047297" from "anon";

revoke trigger on table "temp"."followers_1211134623285047297" from "anon";

revoke truncate on table "temp"."followers_1211134623285047297" from "anon";

revoke update on table "temp"."followers_1211134623285047297" from "anon";

revoke delete on table "temp"."followers_1211134623285047297" from "authenticated";

revoke insert on table "temp"."followers_1211134623285047297" from "authenticated";

revoke references on table "temp"."followers_1211134623285047297" from "authenticated";

revoke select on table "temp"."followers_1211134623285047297" from "authenticated";

revoke trigger on table "temp"."followers_1211134623285047297" from "authenticated";

revoke truncate on table "temp"."followers_1211134623285047297" from "authenticated";

revoke update on table "temp"."followers_1211134623285047297" from "authenticated";

revoke delete on table "temp"."followers_1211134623285047297" from "service_role";

revoke insert on table "temp"."followers_1211134623285047297" from "service_role";

revoke references on table "temp"."followers_1211134623285047297" from "service_role";

revoke select on table "temp"."followers_1211134623285047297" from "service_role";

revoke trigger on table "temp"."followers_1211134623285047297" from "service_role";

revoke truncate on table "temp"."followers_1211134623285047297" from "service_role";

revoke update on table "temp"."followers_1211134623285047297" from "service_role";

revoke delete on table "temp"."followers_1378862677871751174" from "anon";

revoke insert on table "temp"."followers_1378862677871751174" from "anon";

revoke references on table "temp"."followers_1378862677871751174" from "anon";

revoke select on table "temp"."followers_1378862677871751174" from "anon";

revoke trigger on table "temp"."followers_1378862677871751174" from "anon";

revoke truncate on table "temp"."followers_1378862677871751174" from "anon";

revoke update on table "temp"."followers_1378862677871751174" from "anon";

revoke delete on table "temp"."followers_1378862677871751174" from "authenticated";

revoke insert on table "temp"."followers_1378862677871751174" from "authenticated";

revoke references on table "temp"."followers_1378862677871751174" from "authenticated";

revoke select on table "temp"."followers_1378862677871751174" from "authenticated";

revoke trigger on table "temp"."followers_1378862677871751174" from "authenticated";

revoke truncate on table "temp"."followers_1378862677871751174" from "authenticated";

revoke update on table "temp"."followers_1378862677871751174" from "authenticated";

revoke delete on table "temp"."followers_1378862677871751174" from "service_role";

revoke insert on table "temp"."followers_1378862677871751174" from "service_role";

revoke references on table "temp"."followers_1378862677871751174" from "service_role";

revoke select on table "temp"."followers_1378862677871751174" from "service_role";

revoke trigger on table "temp"."followers_1378862677871751174" from "service_role";

revoke truncate on table "temp"."followers_1378862677871751174" from "service_role";

revoke update on table "temp"."followers_1378862677871751174" from "service_role";

revoke delete on table "temp"."followers_316970336" from "anon";

revoke insert on table "temp"."followers_316970336" from "anon";

revoke references on table "temp"."followers_316970336" from "anon";

revoke select on table "temp"."followers_316970336" from "anon";

revoke trigger on table "temp"."followers_316970336" from "anon";

revoke truncate on table "temp"."followers_316970336" from "anon";

revoke update on table "temp"."followers_316970336" from "anon";

revoke delete on table "temp"."followers_316970336" from "authenticated";

revoke insert on table "temp"."followers_316970336" from "authenticated";

revoke references on table "temp"."followers_316970336" from "authenticated";

revoke select on table "temp"."followers_316970336" from "authenticated";

revoke trigger on table "temp"."followers_316970336" from "authenticated";

revoke truncate on table "temp"."followers_316970336" from "authenticated";

revoke update on table "temp"."followers_316970336" from "authenticated";

revoke delete on table "temp"."followers_316970336" from "service_role";

revoke insert on table "temp"."followers_316970336" from "service_role";

revoke references on table "temp"."followers_316970336" from "service_role";

revoke select on table "temp"."followers_316970336" from "service_role";

revoke trigger on table "temp"."followers_316970336" from "service_role";

revoke truncate on table "temp"."followers_316970336" from "service_role";

revoke update on table "temp"."followers_316970336" from "service_role";

revoke delete on table "temp"."following_1038586640" from "anon";

revoke insert on table "temp"."following_1038586640" from "anon";

revoke references on table "temp"."following_1038586640" from "anon";

revoke select on table "temp"."following_1038586640" from "anon";

revoke trigger on table "temp"."following_1038586640" from "anon";

revoke truncate on table "temp"."following_1038586640" from "anon";

revoke update on table "temp"."following_1038586640" from "anon";

revoke delete on table "temp"."following_1038586640" from "authenticated";

revoke insert on table "temp"."following_1038586640" from "authenticated";

revoke references on table "temp"."following_1038586640" from "authenticated";

revoke select on table "temp"."following_1038586640" from "authenticated";

revoke trigger on table "temp"."following_1038586640" from "authenticated";

revoke truncate on table "temp"."following_1038586640" from "authenticated";

revoke update on table "temp"."following_1038586640" from "authenticated";

revoke delete on table "temp"."following_1038586640" from "service_role";

revoke insert on table "temp"."following_1038586640" from "service_role";

revoke references on table "temp"."following_1038586640" from "service_role";

revoke select on table "temp"."following_1038586640" from "service_role";

revoke trigger on table "temp"."following_1038586640" from "service_role";

revoke truncate on table "temp"."following_1038586640" from "service_role";

revoke update on table "temp"."following_1038586640" from "service_role";

revoke delete on table "temp"."following_1211134623285047297" from "anon";

revoke insert on table "temp"."following_1211134623285047297" from "anon";

revoke references on table "temp"."following_1211134623285047297" from "anon";

revoke select on table "temp"."following_1211134623285047297" from "anon";

revoke trigger on table "temp"."following_1211134623285047297" from "anon";

revoke truncate on table "temp"."following_1211134623285047297" from "anon";

revoke update on table "temp"."following_1211134623285047297" from "anon";

revoke delete on table "temp"."following_1211134623285047297" from "authenticated";

revoke insert on table "temp"."following_1211134623285047297" from "authenticated";

revoke references on table "temp"."following_1211134623285047297" from "authenticated";

revoke select on table "temp"."following_1211134623285047297" from "authenticated";

revoke trigger on table "temp"."following_1211134623285047297" from "authenticated";

revoke truncate on table "temp"."following_1211134623285047297" from "authenticated";

revoke update on table "temp"."following_1211134623285047297" from "authenticated";

revoke delete on table "temp"."following_1211134623285047297" from "service_role";

revoke insert on table "temp"."following_1211134623285047297" from "service_role";

revoke references on table "temp"."following_1211134623285047297" from "service_role";

revoke select on table "temp"."following_1211134623285047297" from "service_role";

revoke trigger on table "temp"."following_1211134623285047297" from "service_role";

revoke truncate on table "temp"."following_1211134623285047297" from "service_role";

revoke update on table "temp"."following_1211134623285047297" from "service_role";

revoke delete on table "temp"."following_1378862677871751174" from "anon";

revoke insert on table "temp"."following_1378862677871751174" from "anon";

revoke references on table "temp"."following_1378862677871751174" from "anon";

revoke select on table "temp"."following_1378862677871751174" from "anon";

revoke trigger on table "temp"."following_1378862677871751174" from "anon";

revoke truncate on table "temp"."following_1378862677871751174" from "anon";

revoke update on table "temp"."following_1378862677871751174" from "anon";

revoke delete on table "temp"."following_1378862677871751174" from "authenticated";

revoke insert on table "temp"."following_1378862677871751174" from "authenticated";

revoke references on table "temp"."following_1378862677871751174" from "authenticated";

revoke select on table "temp"."following_1378862677871751174" from "authenticated";

revoke trigger on table "temp"."following_1378862677871751174" from "authenticated";

revoke truncate on table "temp"."following_1378862677871751174" from "authenticated";

revoke update on table "temp"."following_1378862677871751174" from "authenticated";

revoke delete on table "temp"."following_1378862677871751174" from "service_role";

revoke insert on table "temp"."following_1378862677871751174" from "service_role";

revoke references on table "temp"."following_1378862677871751174" from "service_role";

revoke select on table "temp"."following_1378862677871751174" from "service_role";

revoke trigger on table "temp"."following_1378862677871751174" from "service_role";

revoke truncate on table "temp"."following_1378862677871751174" from "service_role";

revoke update on table "temp"."following_1378862677871751174" from "service_role";

revoke delete on table "temp"."following_316970336" from "anon";

revoke insert on table "temp"."following_316970336" from "anon";

revoke references on table "temp"."following_316970336" from "anon";

revoke select on table "temp"."following_316970336" from "anon";

revoke trigger on table "temp"."following_316970336" from "anon";

revoke truncate on table "temp"."following_316970336" from "anon";

revoke update on table "temp"."following_316970336" from "anon";

revoke delete on table "temp"."following_316970336" from "authenticated";

revoke insert on table "temp"."following_316970336" from "authenticated";

revoke references on table "temp"."following_316970336" from "authenticated";

revoke select on table "temp"."following_316970336" from "authenticated";

revoke trigger on table "temp"."following_316970336" from "authenticated";

revoke truncate on table "temp"."following_316970336" from "authenticated";

revoke update on table "temp"."following_316970336" from "authenticated";

revoke delete on table "temp"."following_316970336" from "service_role";

revoke insert on table "temp"."following_316970336" from "service_role";

revoke references on table "temp"."following_316970336" from "service_role";

revoke select on table "temp"."following_316970336" from "service_role";

revoke trigger on table "temp"."following_316970336" from "service_role";

revoke truncate on table "temp"."following_316970336" from "service_role";

revoke update on table "temp"."following_316970336" from "service_role";

revoke delete on table "temp"."liked_tweets_1038586640" from "anon";

revoke insert on table "temp"."liked_tweets_1038586640" from "anon";

revoke references on table "temp"."liked_tweets_1038586640" from "anon";

revoke select on table "temp"."liked_tweets_1038586640" from "anon";

revoke trigger on table "temp"."liked_tweets_1038586640" from "anon";

revoke truncate on table "temp"."liked_tweets_1038586640" from "anon";

revoke update on table "temp"."liked_tweets_1038586640" from "anon";

revoke delete on table "temp"."liked_tweets_1038586640" from "authenticated";

revoke insert on table "temp"."liked_tweets_1038586640" from "authenticated";

revoke references on table "temp"."liked_tweets_1038586640" from "authenticated";

revoke select on table "temp"."liked_tweets_1038586640" from "authenticated";

revoke trigger on table "temp"."liked_tweets_1038586640" from "authenticated";

revoke truncate on table "temp"."liked_tweets_1038586640" from "authenticated";

revoke update on table "temp"."liked_tweets_1038586640" from "authenticated";

revoke delete on table "temp"."liked_tweets_1038586640" from "service_role";

revoke insert on table "temp"."liked_tweets_1038586640" from "service_role";

revoke references on table "temp"."liked_tweets_1038586640" from "service_role";

revoke select on table "temp"."liked_tweets_1038586640" from "service_role";

revoke trigger on table "temp"."liked_tweets_1038586640" from "service_role";

revoke truncate on table "temp"."liked_tweets_1038586640" from "service_role";

revoke update on table "temp"."liked_tweets_1038586640" from "service_role";

revoke delete on table "temp"."liked_tweets_1211134623285047297" from "anon";

revoke insert on table "temp"."liked_tweets_1211134623285047297" from "anon";

revoke references on table "temp"."liked_tweets_1211134623285047297" from "anon";

revoke select on table "temp"."liked_tweets_1211134623285047297" from "anon";

revoke trigger on table "temp"."liked_tweets_1211134623285047297" from "anon";

revoke truncate on table "temp"."liked_tweets_1211134623285047297" from "anon";

revoke update on table "temp"."liked_tweets_1211134623285047297" from "anon";

revoke delete on table "temp"."liked_tweets_1211134623285047297" from "authenticated";

revoke insert on table "temp"."liked_tweets_1211134623285047297" from "authenticated";

revoke references on table "temp"."liked_tweets_1211134623285047297" from "authenticated";

revoke select on table "temp"."liked_tweets_1211134623285047297" from "authenticated";

revoke trigger on table "temp"."liked_tweets_1211134623285047297" from "authenticated";

revoke truncate on table "temp"."liked_tweets_1211134623285047297" from "authenticated";

revoke update on table "temp"."liked_tweets_1211134623285047297" from "authenticated";

revoke delete on table "temp"."liked_tweets_1211134623285047297" from "service_role";

revoke insert on table "temp"."liked_tweets_1211134623285047297" from "service_role";

revoke references on table "temp"."liked_tweets_1211134623285047297" from "service_role";

revoke select on table "temp"."liked_tweets_1211134623285047297" from "service_role";

revoke trigger on table "temp"."liked_tweets_1211134623285047297" from "service_role";

revoke truncate on table "temp"."liked_tweets_1211134623285047297" from "service_role";

revoke update on table "temp"."liked_tweets_1211134623285047297" from "service_role";

revoke delete on table "temp"."liked_tweets_1378862677871751174" from "anon";

revoke insert on table "temp"."liked_tweets_1378862677871751174" from "anon";

revoke references on table "temp"."liked_tweets_1378862677871751174" from "anon";

revoke select on table "temp"."liked_tweets_1378862677871751174" from "anon";

revoke trigger on table "temp"."liked_tweets_1378862677871751174" from "anon";

revoke truncate on table "temp"."liked_tweets_1378862677871751174" from "anon";

revoke update on table "temp"."liked_tweets_1378862677871751174" from "anon";

revoke delete on table "temp"."liked_tweets_1378862677871751174" from "authenticated";

revoke insert on table "temp"."liked_tweets_1378862677871751174" from "authenticated";

revoke references on table "temp"."liked_tweets_1378862677871751174" from "authenticated";

revoke select on table "temp"."liked_tweets_1378862677871751174" from "authenticated";

revoke trigger on table "temp"."liked_tweets_1378862677871751174" from "authenticated";

revoke truncate on table "temp"."liked_tweets_1378862677871751174" from "authenticated";

revoke update on table "temp"."liked_tweets_1378862677871751174" from "authenticated";

revoke delete on table "temp"."liked_tweets_1378862677871751174" from "service_role";

revoke insert on table "temp"."liked_tweets_1378862677871751174" from "service_role";

revoke references on table "temp"."liked_tweets_1378862677871751174" from "service_role";

revoke select on table "temp"."liked_tweets_1378862677871751174" from "service_role";

revoke trigger on table "temp"."liked_tweets_1378862677871751174" from "service_role";

revoke truncate on table "temp"."liked_tweets_1378862677871751174" from "service_role";

revoke update on table "temp"."liked_tweets_1378862677871751174" from "service_role";

revoke delete on table "temp"."liked_tweets_316970336" from "anon";

revoke insert on table "temp"."liked_tweets_316970336" from "anon";

revoke references on table "temp"."liked_tweets_316970336" from "anon";

revoke select on table "temp"."liked_tweets_316970336" from "anon";

revoke trigger on table "temp"."liked_tweets_316970336" from "anon";

revoke truncate on table "temp"."liked_tweets_316970336" from "anon";

revoke update on table "temp"."liked_tweets_316970336" from "anon";

revoke delete on table "temp"."liked_tweets_316970336" from "authenticated";

revoke insert on table "temp"."liked_tweets_316970336" from "authenticated";

revoke references on table "temp"."liked_tweets_316970336" from "authenticated";

revoke select on table "temp"."liked_tweets_316970336" from "authenticated";

revoke trigger on table "temp"."liked_tweets_316970336" from "authenticated";

revoke truncate on table "temp"."liked_tweets_316970336" from "authenticated";

revoke update on table "temp"."liked_tweets_316970336" from "authenticated";

revoke delete on table "temp"."liked_tweets_316970336" from "service_role";

revoke insert on table "temp"."liked_tweets_316970336" from "service_role";

revoke references on table "temp"."liked_tweets_316970336" from "service_role";

revoke select on table "temp"."liked_tweets_316970336" from "service_role";

revoke trigger on table "temp"."liked_tweets_316970336" from "service_role";

revoke truncate on table "temp"."liked_tweets_316970336" from "service_role";

revoke update on table "temp"."liked_tweets_316970336" from "service_role";

revoke delete on table "temp"."likes_1038586640" from "anon";

revoke insert on table "temp"."likes_1038586640" from "anon";

revoke references on table "temp"."likes_1038586640" from "anon";

revoke select on table "temp"."likes_1038586640" from "anon";

revoke trigger on table "temp"."likes_1038586640" from "anon";

revoke truncate on table "temp"."likes_1038586640" from "anon";

revoke update on table "temp"."likes_1038586640" from "anon";

revoke delete on table "temp"."likes_1038586640" from "authenticated";

revoke insert on table "temp"."likes_1038586640" from "authenticated";

revoke references on table "temp"."likes_1038586640" from "authenticated";

revoke select on table "temp"."likes_1038586640" from "authenticated";

revoke trigger on table "temp"."likes_1038586640" from "authenticated";

revoke truncate on table "temp"."likes_1038586640" from "authenticated";

revoke update on table "temp"."likes_1038586640" from "authenticated";

revoke delete on table "temp"."likes_1038586640" from "service_role";

revoke insert on table "temp"."likes_1038586640" from "service_role";

revoke references on table "temp"."likes_1038586640" from "service_role";

revoke select on table "temp"."likes_1038586640" from "service_role";

revoke trigger on table "temp"."likes_1038586640" from "service_role";

revoke truncate on table "temp"."likes_1038586640" from "service_role";

revoke update on table "temp"."likes_1038586640" from "service_role";

revoke delete on table "temp"."likes_1211134623285047297" from "anon";

revoke insert on table "temp"."likes_1211134623285047297" from "anon";

revoke references on table "temp"."likes_1211134623285047297" from "anon";

revoke select on table "temp"."likes_1211134623285047297" from "anon";

revoke trigger on table "temp"."likes_1211134623285047297" from "anon";

revoke truncate on table "temp"."likes_1211134623285047297" from "anon";

revoke update on table "temp"."likes_1211134623285047297" from "anon";

revoke delete on table "temp"."likes_1211134623285047297" from "authenticated";

revoke insert on table "temp"."likes_1211134623285047297" from "authenticated";

revoke references on table "temp"."likes_1211134623285047297" from "authenticated";

revoke select on table "temp"."likes_1211134623285047297" from "authenticated";

revoke trigger on table "temp"."likes_1211134623285047297" from "authenticated";

revoke truncate on table "temp"."likes_1211134623285047297" from "authenticated";

revoke update on table "temp"."likes_1211134623285047297" from "authenticated";

revoke delete on table "temp"."likes_1211134623285047297" from "service_role";

revoke insert on table "temp"."likes_1211134623285047297" from "service_role";

revoke references on table "temp"."likes_1211134623285047297" from "service_role";

revoke select on table "temp"."likes_1211134623285047297" from "service_role";

revoke trigger on table "temp"."likes_1211134623285047297" from "service_role";

revoke truncate on table "temp"."likes_1211134623285047297" from "service_role";

revoke update on table "temp"."likes_1211134623285047297" from "service_role";

revoke delete on table "temp"."likes_1378862677871751174" from "anon";

revoke insert on table "temp"."likes_1378862677871751174" from "anon";

revoke references on table "temp"."likes_1378862677871751174" from "anon";

revoke select on table "temp"."likes_1378862677871751174" from "anon";

revoke trigger on table "temp"."likes_1378862677871751174" from "anon";

revoke truncate on table "temp"."likes_1378862677871751174" from "anon";

revoke update on table "temp"."likes_1378862677871751174" from "anon";

revoke delete on table "temp"."likes_1378862677871751174" from "authenticated";

revoke insert on table "temp"."likes_1378862677871751174" from "authenticated";

revoke references on table "temp"."likes_1378862677871751174" from "authenticated";

revoke select on table "temp"."likes_1378862677871751174" from "authenticated";

revoke trigger on table "temp"."likes_1378862677871751174" from "authenticated";

revoke truncate on table "temp"."likes_1378862677871751174" from "authenticated";

revoke update on table "temp"."likes_1378862677871751174" from "authenticated";

revoke delete on table "temp"."likes_1378862677871751174" from "service_role";

revoke insert on table "temp"."likes_1378862677871751174" from "service_role";

revoke references on table "temp"."likes_1378862677871751174" from "service_role";

revoke select on table "temp"."likes_1378862677871751174" from "service_role";

revoke trigger on table "temp"."likes_1378862677871751174" from "service_role";

revoke truncate on table "temp"."likes_1378862677871751174" from "service_role";

revoke update on table "temp"."likes_1378862677871751174" from "service_role";

revoke delete on table "temp"."likes_316970336" from "anon";

revoke insert on table "temp"."likes_316970336" from "anon";

revoke references on table "temp"."likes_316970336" from "anon";

revoke select on table "temp"."likes_316970336" from "anon";

revoke trigger on table "temp"."likes_316970336" from "anon";

revoke truncate on table "temp"."likes_316970336" from "anon";

revoke update on table "temp"."likes_316970336" from "anon";

revoke delete on table "temp"."likes_316970336" from "authenticated";

revoke insert on table "temp"."likes_316970336" from "authenticated";

revoke references on table "temp"."likes_316970336" from "authenticated";

revoke select on table "temp"."likes_316970336" from "authenticated";

revoke trigger on table "temp"."likes_316970336" from "authenticated";

revoke truncate on table "temp"."likes_316970336" from "authenticated";

revoke update on table "temp"."likes_316970336" from "authenticated";

revoke delete on table "temp"."likes_316970336" from "service_role";

revoke insert on table "temp"."likes_316970336" from "service_role";

revoke references on table "temp"."likes_316970336" from "service_role";

revoke select on table "temp"."likes_316970336" from "service_role";

revoke trigger on table "temp"."likes_316970336" from "service_role";

revoke truncate on table "temp"."likes_316970336" from "service_role";

revoke update on table "temp"."likes_316970336" from "service_role";

revoke delete on table "temp"."mentioned_users_1038586640" from "anon";

revoke insert on table "temp"."mentioned_users_1038586640" from "anon";

revoke references on table "temp"."mentioned_users_1038586640" from "anon";

revoke select on table "temp"."mentioned_users_1038586640" from "anon";

revoke trigger on table "temp"."mentioned_users_1038586640" from "anon";

revoke truncate on table "temp"."mentioned_users_1038586640" from "anon";

revoke update on table "temp"."mentioned_users_1038586640" from "anon";

revoke delete on table "temp"."mentioned_users_1038586640" from "authenticated";

revoke insert on table "temp"."mentioned_users_1038586640" from "authenticated";

revoke references on table "temp"."mentioned_users_1038586640" from "authenticated";

revoke select on table "temp"."mentioned_users_1038586640" from "authenticated";

revoke trigger on table "temp"."mentioned_users_1038586640" from "authenticated";

revoke truncate on table "temp"."mentioned_users_1038586640" from "authenticated";

revoke update on table "temp"."mentioned_users_1038586640" from "authenticated";

revoke delete on table "temp"."mentioned_users_1038586640" from "service_role";

revoke insert on table "temp"."mentioned_users_1038586640" from "service_role";

revoke references on table "temp"."mentioned_users_1038586640" from "service_role";

revoke select on table "temp"."mentioned_users_1038586640" from "service_role";

revoke trigger on table "temp"."mentioned_users_1038586640" from "service_role";

revoke truncate on table "temp"."mentioned_users_1038586640" from "service_role";

revoke update on table "temp"."mentioned_users_1038586640" from "service_role";

revoke delete on table "temp"."mentioned_users_1211134623285047297" from "anon";

revoke insert on table "temp"."mentioned_users_1211134623285047297" from "anon";

revoke references on table "temp"."mentioned_users_1211134623285047297" from "anon";

revoke select on table "temp"."mentioned_users_1211134623285047297" from "anon";

revoke trigger on table "temp"."mentioned_users_1211134623285047297" from "anon";

revoke truncate on table "temp"."mentioned_users_1211134623285047297" from "anon";

revoke update on table "temp"."mentioned_users_1211134623285047297" from "anon";

revoke delete on table "temp"."mentioned_users_1211134623285047297" from "authenticated";

revoke insert on table "temp"."mentioned_users_1211134623285047297" from "authenticated";

revoke references on table "temp"."mentioned_users_1211134623285047297" from "authenticated";

revoke select on table "temp"."mentioned_users_1211134623285047297" from "authenticated";

revoke trigger on table "temp"."mentioned_users_1211134623285047297" from "authenticated";

revoke truncate on table "temp"."mentioned_users_1211134623285047297" from "authenticated";

revoke update on table "temp"."mentioned_users_1211134623285047297" from "authenticated";

revoke delete on table "temp"."mentioned_users_1211134623285047297" from "service_role";

revoke insert on table "temp"."mentioned_users_1211134623285047297" from "service_role";

revoke references on table "temp"."mentioned_users_1211134623285047297" from "service_role";

revoke select on table "temp"."mentioned_users_1211134623285047297" from "service_role";

revoke trigger on table "temp"."mentioned_users_1211134623285047297" from "service_role";

revoke truncate on table "temp"."mentioned_users_1211134623285047297" from "service_role";

revoke update on table "temp"."mentioned_users_1211134623285047297" from "service_role";

revoke delete on table "temp"."mentioned_users_1378862677871751174" from "anon";

revoke insert on table "temp"."mentioned_users_1378862677871751174" from "anon";

revoke references on table "temp"."mentioned_users_1378862677871751174" from "anon";

revoke select on table "temp"."mentioned_users_1378862677871751174" from "anon";

revoke trigger on table "temp"."mentioned_users_1378862677871751174" from "anon";

revoke truncate on table "temp"."mentioned_users_1378862677871751174" from "anon";

revoke update on table "temp"."mentioned_users_1378862677871751174" from "anon";

revoke delete on table "temp"."mentioned_users_1378862677871751174" from "authenticated";

revoke insert on table "temp"."mentioned_users_1378862677871751174" from "authenticated";

revoke references on table "temp"."mentioned_users_1378862677871751174" from "authenticated";

revoke select on table "temp"."mentioned_users_1378862677871751174" from "authenticated";

revoke trigger on table "temp"."mentioned_users_1378862677871751174" from "authenticated";

revoke truncate on table "temp"."mentioned_users_1378862677871751174" from "authenticated";

revoke update on table "temp"."mentioned_users_1378862677871751174" from "authenticated";

revoke delete on table "temp"."mentioned_users_1378862677871751174" from "service_role";

revoke insert on table "temp"."mentioned_users_1378862677871751174" from "service_role";

revoke references on table "temp"."mentioned_users_1378862677871751174" from "service_role";

revoke select on table "temp"."mentioned_users_1378862677871751174" from "service_role";

revoke trigger on table "temp"."mentioned_users_1378862677871751174" from "service_role";

revoke truncate on table "temp"."mentioned_users_1378862677871751174" from "service_role";

revoke update on table "temp"."mentioned_users_1378862677871751174" from "service_role";

revoke delete on table "temp"."mentioned_users_316970336" from "anon";

revoke insert on table "temp"."mentioned_users_316970336" from "anon";

revoke references on table "temp"."mentioned_users_316970336" from "anon";

revoke select on table "temp"."mentioned_users_316970336" from "anon";

revoke trigger on table "temp"."mentioned_users_316970336" from "anon";

revoke truncate on table "temp"."mentioned_users_316970336" from "anon";

revoke update on table "temp"."mentioned_users_316970336" from "anon";

revoke delete on table "temp"."mentioned_users_316970336" from "authenticated";

revoke insert on table "temp"."mentioned_users_316970336" from "authenticated";

revoke references on table "temp"."mentioned_users_316970336" from "authenticated";

revoke select on table "temp"."mentioned_users_316970336" from "authenticated";

revoke trigger on table "temp"."mentioned_users_316970336" from "authenticated";

revoke truncate on table "temp"."mentioned_users_316970336" from "authenticated";

revoke update on table "temp"."mentioned_users_316970336" from "authenticated";

revoke delete on table "temp"."mentioned_users_316970336" from "service_role";

revoke insert on table "temp"."mentioned_users_316970336" from "service_role";

revoke references on table "temp"."mentioned_users_316970336" from "service_role";

revoke select on table "temp"."mentioned_users_316970336" from "service_role";

revoke trigger on table "temp"."mentioned_users_316970336" from "service_role";

revoke truncate on table "temp"."mentioned_users_316970336" from "service_role";

revoke update on table "temp"."mentioned_users_316970336" from "service_role";

revoke delete on table "temp"."profile_1038586640" from "anon";

revoke insert on table "temp"."profile_1038586640" from "anon";

revoke references on table "temp"."profile_1038586640" from "anon";

revoke select on table "temp"."profile_1038586640" from "anon";

revoke trigger on table "temp"."profile_1038586640" from "anon";

revoke truncate on table "temp"."profile_1038586640" from "anon";

revoke update on table "temp"."profile_1038586640" from "anon";

revoke delete on table "temp"."profile_1038586640" from "authenticated";

revoke insert on table "temp"."profile_1038586640" from "authenticated";

revoke references on table "temp"."profile_1038586640" from "authenticated";

revoke select on table "temp"."profile_1038586640" from "authenticated";

revoke trigger on table "temp"."profile_1038586640" from "authenticated";

revoke truncate on table "temp"."profile_1038586640" from "authenticated";

revoke update on table "temp"."profile_1038586640" from "authenticated";

revoke delete on table "temp"."profile_1038586640" from "service_role";

revoke insert on table "temp"."profile_1038586640" from "service_role";

revoke references on table "temp"."profile_1038586640" from "service_role";

revoke select on table "temp"."profile_1038586640" from "service_role";

revoke trigger on table "temp"."profile_1038586640" from "service_role";

revoke truncate on table "temp"."profile_1038586640" from "service_role";

revoke update on table "temp"."profile_1038586640" from "service_role";

revoke delete on table "temp"."profile_1211134623285047297" from "anon";

revoke insert on table "temp"."profile_1211134623285047297" from "anon";

revoke references on table "temp"."profile_1211134623285047297" from "anon";

revoke select on table "temp"."profile_1211134623285047297" from "anon";

revoke trigger on table "temp"."profile_1211134623285047297" from "anon";

revoke truncate on table "temp"."profile_1211134623285047297" from "anon";

revoke update on table "temp"."profile_1211134623285047297" from "anon";

revoke delete on table "temp"."profile_1211134623285047297" from "authenticated";

revoke insert on table "temp"."profile_1211134623285047297" from "authenticated";

revoke references on table "temp"."profile_1211134623285047297" from "authenticated";

revoke select on table "temp"."profile_1211134623285047297" from "authenticated";

revoke trigger on table "temp"."profile_1211134623285047297" from "authenticated";

revoke truncate on table "temp"."profile_1211134623285047297" from "authenticated";

revoke update on table "temp"."profile_1211134623285047297" from "authenticated";

revoke delete on table "temp"."profile_1211134623285047297" from "service_role";

revoke insert on table "temp"."profile_1211134623285047297" from "service_role";

revoke references on table "temp"."profile_1211134623285047297" from "service_role";

revoke select on table "temp"."profile_1211134623285047297" from "service_role";

revoke trigger on table "temp"."profile_1211134623285047297" from "service_role";

revoke truncate on table "temp"."profile_1211134623285047297" from "service_role";

revoke update on table "temp"."profile_1211134623285047297" from "service_role";

revoke delete on table "temp"."profile_1378862677871751174" from "anon";

revoke insert on table "temp"."profile_1378862677871751174" from "anon";

revoke references on table "temp"."profile_1378862677871751174" from "anon";

revoke select on table "temp"."profile_1378862677871751174" from "anon";

revoke trigger on table "temp"."profile_1378862677871751174" from "anon";

revoke truncate on table "temp"."profile_1378862677871751174" from "anon";

revoke update on table "temp"."profile_1378862677871751174" from "anon";

revoke delete on table "temp"."profile_1378862677871751174" from "authenticated";

revoke insert on table "temp"."profile_1378862677871751174" from "authenticated";

revoke references on table "temp"."profile_1378862677871751174" from "authenticated";

revoke select on table "temp"."profile_1378862677871751174" from "authenticated";

revoke trigger on table "temp"."profile_1378862677871751174" from "authenticated";

revoke truncate on table "temp"."profile_1378862677871751174" from "authenticated";

revoke update on table "temp"."profile_1378862677871751174" from "authenticated";

revoke delete on table "temp"."profile_1378862677871751174" from "service_role";

revoke insert on table "temp"."profile_1378862677871751174" from "service_role";

revoke references on table "temp"."profile_1378862677871751174" from "service_role";

revoke select on table "temp"."profile_1378862677871751174" from "service_role";

revoke trigger on table "temp"."profile_1378862677871751174" from "service_role";

revoke truncate on table "temp"."profile_1378862677871751174" from "service_role";

revoke update on table "temp"."profile_1378862677871751174" from "service_role";

revoke delete on table "temp"."profile_316970336" from "anon";

revoke insert on table "temp"."profile_316970336" from "anon";

revoke references on table "temp"."profile_316970336" from "anon";

revoke select on table "temp"."profile_316970336" from "anon";

revoke trigger on table "temp"."profile_316970336" from "anon";

revoke truncate on table "temp"."profile_316970336" from "anon";

revoke update on table "temp"."profile_316970336" from "anon";

revoke delete on table "temp"."profile_316970336" from "authenticated";

revoke insert on table "temp"."profile_316970336" from "authenticated";

revoke references on table "temp"."profile_316970336" from "authenticated";

revoke select on table "temp"."profile_316970336" from "authenticated";

revoke trigger on table "temp"."profile_316970336" from "authenticated";

revoke truncate on table "temp"."profile_316970336" from "authenticated";

revoke update on table "temp"."profile_316970336" from "authenticated";

revoke delete on table "temp"."profile_316970336" from "service_role";

revoke insert on table "temp"."profile_316970336" from "service_role";

revoke references on table "temp"."profile_316970336" from "service_role";

revoke select on table "temp"."profile_316970336" from "service_role";

revoke trigger on table "temp"."profile_316970336" from "service_role";

revoke truncate on table "temp"."profile_316970336" from "service_role";

revoke update on table "temp"."profile_316970336" from "service_role";

revoke delete on table "temp"."tweet_media_1038586640" from "anon";

revoke insert on table "temp"."tweet_media_1038586640" from "anon";

revoke references on table "temp"."tweet_media_1038586640" from "anon";

revoke select on table "temp"."tweet_media_1038586640" from "anon";

revoke trigger on table "temp"."tweet_media_1038586640" from "anon";

revoke truncate on table "temp"."tweet_media_1038586640" from "anon";

revoke update on table "temp"."tweet_media_1038586640" from "anon";

revoke delete on table "temp"."tweet_media_1038586640" from "authenticated";

revoke insert on table "temp"."tweet_media_1038586640" from "authenticated";

revoke references on table "temp"."tweet_media_1038586640" from "authenticated";

revoke select on table "temp"."tweet_media_1038586640" from "authenticated";

revoke trigger on table "temp"."tweet_media_1038586640" from "authenticated";

revoke truncate on table "temp"."tweet_media_1038586640" from "authenticated";

revoke update on table "temp"."tweet_media_1038586640" from "authenticated";

revoke delete on table "temp"."tweet_media_1038586640" from "service_role";

revoke insert on table "temp"."tweet_media_1038586640" from "service_role";

revoke references on table "temp"."tweet_media_1038586640" from "service_role";

revoke select on table "temp"."tweet_media_1038586640" from "service_role";

revoke trigger on table "temp"."tweet_media_1038586640" from "service_role";

revoke truncate on table "temp"."tweet_media_1038586640" from "service_role";

revoke update on table "temp"."tweet_media_1038586640" from "service_role";

revoke delete on table "temp"."tweet_media_1211134623285047297" from "anon";

revoke insert on table "temp"."tweet_media_1211134623285047297" from "anon";

revoke references on table "temp"."tweet_media_1211134623285047297" from "anon";

revoke select on table "temp"."tweet_media_1211134623285047297" from "anon";

revoke trigger on table "temp"."tweet_media_1211134623285047297" from "anon";

revoke truncate on table "temp"."tweet_media_1211134623285047297" from "anon";

revoke update on table "temp"."tweet_media_1211134623285047297" from "anon";

revoke delete on table "temp"."tweet_media_1211134623285047297" from "authenticated";

revoke insert on table "temp"."tweet_media_1211134623285047297" from "authenticated";

revoke references on table "temp"."tweet_media_1211134623285047297" from "authenticated";

revoke select on table "temp"."tweet_media_1211134623285047297" from "authenticated";

revoke trigger on table "temp"."tweet_media_1211134623285047297" from "authenticated";

revoke truncate on table "temp"."tweet_media_1211134623285047297" from "authenticated";

revoke update on table "temp"."tweet_media_1211134623285047297" from "authenticated";

revoke delete on table "temp"."tweet_media_1211134623285047297" from "service_role";

revoke insert on table "temp"."tweet_media_1211134623285047297" from "service_role";

revoke references on table "temp"."tweet_media_1211134623285047297" from "service_role";

revoke select on table "temp"."tweet_media_1211134623285047297" from "service_role";

revoke trigger on table "temp"."tweet_media_1211134623285047297" from "service_role";

revoke truncate on table "temp"."tweet_media_1211134623285047297" from "service_role";

revoke update on table "temp"."tweet_media_1211134623285047297" from "service_role";

revoke delete on table "temp"."tweet_media_1378862677871751174" from "anon";

revoke insert on table "temp"."tweet_media_1378862677871751174" from "anon";

revoke references on table "temp"."tweet_media_1378862677871751174" from "anon";

revoke select on table "temp"."tweet_media_1378862677871751174" from "anon";

revoke trigger on table "temp"."tweet_media_1378862677871751174" from "anon";

revoke truncate on table "temp"."tweet_media_1378862677871751174" from "anon";

revoke update on table "temp"."tweet_media_1378862677871751174" from "anon";

revoke delete on table "temp"."tweet_media_1378862677871751174" from "authenticated";

revoke insert on table "temp"."tweet_media_1378862677871751174" from "authenticated";

revoke references on table "temp"."tweet_media_1378862677871751174" from "authenticated";

revoke select on table "temp"."tweet_media_1378862677871751174" from "authenticated";

revoke trigger on table "temp"."tweet_media_1378862677871751174" from "authenticated";

revoke truncate on table "temp"."tweet_media_1378862677871751174" from "authenticated";

revoke update on table "temp"."tweet_media_1378862677871751174" from "authenticated";

revoke delete on table "temp"."tweet_media_1378862677871751174" from "service_role";

revoke insert on table "temp"."tweet_media_1378862677871751174" from "service_role";

revoke references on table "temp"."tweet_media_1378862677871751174" from "service_role";

revoke select on table "temp"."tweet_media_1378862677871751174" from "service_role";

revoke trigger on table "temp"."tweet_media_1378862677871751174" from "service_role";

revoke truncate on table "temp"."tweet_media_1378862677871751174" from "service_role";

revoke update on table "temp"."tweet_media_1378862677871751174" from "service_role";

revoke delete on table "temp"."tweet_media_316970336" from "anon";

revoke insert on table "temp"."tweet_media_316970336" from "anon";

revoke references on table "temp"."tweet_media_316970336" from "anon";

revoke select on table "temp"."tweet_media_316970336" from "anon";

revoke trigger on table "temp"."tweet_media_316970336" from "anon";

revoke truncate on table "temp"."tweet_media_316970336" from "anon";

revoke update on table "temp"."tweet_media_316970336" from "anon";

revoke delete on table "temp"."tweet_media_316970336" from "authenticated";

revoke insert on table "temp"."tweet_media_316970336" from "authenticated";

revoke references on table "temp"."tweet_media_316970336" from "authenticated";

revoke select on table "temp"."tweet_media_316970336" from "authenticated";

revoke trigger on table "temp"."tweet_media_316970336" from "authenticated";

revoke truncate on table "temp"."tweet_media_316970336" from "authenticated";

revoke update on table "temp"."tweet_media_316970336" from "authenticated";

revoke delete on table "temp"."tweet_media_316970336" from "service_role";

revoke insert on table "temp"."tweet_media_316970336" from "service_role";

revoke references on table "temp"."tweet_media_316970336" from "service_role";

revoke select on table "temp"."tweet_media_316970336" from "service_role";

revoke trigger on table "temp"."tweet_media_316970336" from "service_role";

revoke truncate on table "temp"."tweet_media_316970336" from "service_role";

revoke update on table "temp"."tweet_media_316970336" from "service_role";

revoke delete on table "temp"."tweet_urls_1038586640" from "anon";

revoke insert on table "temp"."tweet_urls_1038586640" from "anon";

revoke references on table "temp"."tweet_urls_1038586640" from "anon";

revoke select on table "temp"."tweet_urls_1038586640" from "anon";

revoke trigger on table "temp"."tweet_urls_1038586640" from "anon";

revoke truncate on table "temp"."tweet_urls_1038586640" from "anon";

revoke update on table "temp"."tweet_urls_1038586640" from "anon";

revoke delete on table "temp"."tweet_urls_1038586640" from "authenticated";

revoke insert on table "temp"."tweet_urls_1038586640" from "authenticated";

revoke references on table "temp"."tweet_urls_1038586640" from "authenticated";

revoke select on table "temp"."tweet_urls_1038586640" from "authenticated";

revoke trigger on table "temp"."tweet_urls_1038586640" from "authenticated";

revoke truncate on table "temp"."tweet_urls_1038586640" from "authenticated";

revoke update on table "temp"."tweet_urls_1038586640" from "authenticated";

revoke delete on table "temp"."tweet_urls_1038586640" from "service_role";

revoke insert on table "temp"."tweet_urls_1038586640" from "service_role";

revoke references on table "temp"."tweet_urls_1038586640" from "service_role";

revoke select on table "temp"."tweet_urls_1038586640" from "service_role";

revoke trigger on table "temp"."tweet_urls_1038586640" from "service_role";

revoke truncate on table "temp"."tweet_urls_1038586640" from "service_role";

revoke update on table "temp"."tweet_urls_1038586640" from "service_role";

revoke delete on table "temp"."tweet_urls_1211134623285047297" from "anon";

revoke insert on table "temp"."tweet_urls_1211134623285047297" from "anon";

revoke references on table "temp"."tweet_urls_1211134623285047297" from "anon";

revoke select on table "temp"."tweet_urls_1211134623285047297" from "anon";

revoke trigger on table "temp"."tweet_urls_1211134623285047297" from "anon";

revoke truncate on table "temp"."tweet_urls_1211134623285047297" from "anon";

revoke update on table "temp"."tweet_urls_1211134623285047297" from "anon";

revoke delete on table "temp"."tweet_urls_1211134623285047297" from "authenticated";

revoke insert on table "temp"."tweet_urls_1211134623285047297" from "authenticated";

revoke references on table "temp"."tweet_urls_1211134623285047297" from "authenticated";

revoke select on table "temp"."tweet_urls_1211134623285047297" from "authenticated";

revoke trigger on table "temp"."tweet_urls_1211134623285047297" from "authenticated";

revoke truncate on table "temp"."tweet_urls_1211134623285047297" from "authenticated";

revoke update on table "temp"."tweet_urls_1211134623285047297" from "authenticated";

revoke delete on table "temp"."tweet_urls_1211134623285047297" from "service_role";

revoke insert on table "temp"."tweet_urls_1211134623285047297" from "service_role";

revoke references on table "temp"."tweet_urls_1211134623285047297" from "service_role";

revoke select on table "temp"."tweet_urls_1211134623285047297" from "service_role";

revoke trigger on table "temp"."tweet_urls_1211134623285047297" from "service_role";

revoke truncate on table "temp"."tweet_urls_1211134623285047297" from "service_role";

revoke update on table "temp"."tweet_urls_1211134623285047297" from "service_role";

revoke delete on table "temp"."tweet_urls_1378862677871751174" from "anon";

revoke insert on table "temp"."tweet_urls_1378862677871751174" from "anon";

revoke references on table "temp"."tweet_urls_1378862677871751174" from "anon";

revoke select on table "temp"."tweet_urls_1378862677871751174" from "anon";

revoke trigger on table "temp"."tweet_urls_1378862677871751174" from "anon";

revoke truncate on table "temp"."tweet_urls_1378862677871751174" from "anon";

revoke update on table "temp"."tweet_urls_1378862677871751174" from "anon";

revoke delete on table "temp"."tweet_urls_1378862677871751174" from "authenticated";

revoke insert on table "temp"."tweet_urls_1378862677871751174" from "authenticated";

revoke references on table "temp"."tweet_urls_1378862677871751174" from "authenticated";

revoke select on table "temp"."tweet_urls_1378862677871751174" from "authenticated";

revoke trigger on table "temp"."tweet_urls_1378862677871751174" from "authenticated";

revoke truncate on table "temp"."tweet_urls_1378862677871751174" from "authenticated";

revoke update on table "temp"."tweet_urls_1378862677871751174" from "authenticated";

revoke delete on table "temp"."tweet_urls_1378862677871751174" from "service_role";

revoke insert on table "temp"."tweet_urls_1378862677871751174" from "service_role";

revoke references on table "temp"."tweet_urls_1378862677871751174" from "service_role";

revoke select on table "temp"."tweet_urls_1378862677871751174" from "service_role";

revoke trigger on table "temp"."tweet_urls_1378862677871751174" from "service_role";

revoke truncate on table "temp"."tweet_urls_1378862677871751174" from "service_role";

revoke update on table "temp"."tweet_urls_1378862677871751174" from "service_role";

revoke delete on table "temp"."tweet_urls_316970336" from "anon";

revoke insert on table "temp"."tweet_urls_316970336" from "anon";

revoke references on table "temp"."tweet_urls_316970336" from "anon";

revoke select on table "temp"."tweet_urls_316970336" from "anon";

revoke trigger on table "temp"."tweet_urls_316970336" from "anon";

revoke truncate on table "temp"."tweet_urls_316970336" from "anon";

revoke update on table "temp"."tweet_urls_316970336" from "anon";

revoke delete on table "temp"."tweet_urls_316970336" from "authenticated";

revoke insert on table "temp"."tweet_urls_316970336" from "authenticated";

revoke references on table "temp"."tweet_urls_316970336" from "authenticated";

revoke select on table "temp"."tweet_urls_316970336" from "authenticated";

revoke trigger on table "temp"."tweet_urls_316970336" from "authenticated";

revoke truncate on table "temp"."tweet_urls_316970336" from "authenticated";

revoke update on table "temp"."tweet_urls_316970336" from "authenticated";

revoke delete on table "temp"."tweet_urls_316970336" from "service_role";

revoke insert on table "temp"."tweet_urls_316970336" from "service_role";

revoke references on table "temp"."tweet_urls_316970336" from "service_role";

revoke select on table "temp"."tweet_urls_316970336" from "service_role";

revoke trigger on table "temp"."tweet_urls_316970336" from "service_role";

revoke truncate on table "temp"."tweet_urls_316970336" from "service_role";

revoke update on table "temp"."tweet_urls_316970336" from "service_role";

revoke delete on table "temp"."tweets_1038586640" from "anon";

revoke insert on table "temp"."tweets_1038586640" from "anon";

revoke references on table "temp"."tweets_1038586640" from "anon";

revoke select on table "temp"."tweets_1038586640" from "anon";

revoke trigger on table "temp"."tweets_1038586640" from "anon";

revoke truncate on table "temp"."tweets_1038586640" from "anon";

revoke update on table "temp"."tweets_1038586640" from "anon";

revoke delete on table "temp"."tweets_1038586640" from "authenticated";

revoke insert on table "temp"."tweets_1038586640" from "authenticated";

revoke references on table "temp"."tweets_1038586640" from "authenticated";

revoke select on table "temp"."tweets_1038586640" from "authenticated";

revoke trigger on table "temp"."tweets_1038586640" from "authenticated";

revoke truncate on table "temp"."tweets_1038586640" from "authenticated";

revoke update on table "temp"."tweets_1038586640" from "authenticated";

revoke delete on table "temp"."tweets_1038586640" from "service_role";

revoke insert on table "temp"."tweets_1038586640" from "service_role";

revoke references on table "temp"."tweets_1038586640" from "service_role";

revoke select on table "temp"."tweets_1038586640" from "service_role";

revoke trigger on table "temp"."tweets_1038586640" from "service_role";

revoke truncate on table "temp"."tweets_1038586640" from "service_role";

revoke update on table "temp"."tweets_1038586640" from "service_role";

revoke delete on table "temp"."tweets_1211134623285047297" from "anon";

revoke insert on table "temp"."tweets_1211134623285047297" from "anon";

revoke references on table "temp"."tweets_1211134623285047297" from "anon";

revoke select on table "temp"."tweets_1211134623285047297" from "anon";

revoke trigger on table "temp"."tweets_1211134623285047297" from "anon";

revoke truncate on table "temp"."tweets_1211134623285047297" from "anon";

revoke update on table "temp"."tweets_1211134623285047297" from "anon";

revoke delete on table "temp"."tweets_1211134623285047297" from "authenticated";

revoke insert on table "temp"."tweets_1211134623285047297" from "authenticated";

revoke references on table "temp"."tweets_1211134623285047297" from "authenticated";

revoke select on table "temp"."tweets_1211134623285047297" from "authenticated";

revoke trigger on table "temp"."tweets_1211134623285047297" from "authenticated";

revoke truncate on table "temp"."tweets_1211134623285047297" from "authenticated";

revoke update on table "temp"."tweets_1211134623285047297" from "authenticated";

revoke delete on table "temp"."tweets_1211134623285047297" from "service_role";

revoke insert on table "temp"."tweets_1211134623285047297" from "service_role";

revoke references on table "temp"."tweets_1211134623285047297" from "service_role";

revoke select on table "temp"."tweets_1211134623285047297" from "service_role";

revoke trigger on table "temp"."tweets_1211134623285047297" from "service_role";

revoke truncate on table "temp"."tweets_1211134623285047297" from "service_role";

revoke update on table "temp"."tweets_1211134623285047297" from "service_role";

revoke delete on table "temp"."tweets_1378862677871751174" from "anon";

revoke insert on table "temp"."tweets_1378862677871751174" from "anon";

revoke references on table "temp"."tweets_1378862677871751174" from "anon";

revoke select on table "temp"."tweets_1378862677871751174" from "anon";

revoke trigger on table "temp"."tweets_1378862677871751174" from "anon";

revoke truncate on table "temp"."tweets_1378862677871751174" from "anon";

revoke update on table "temp"."tweets_1378862677871751174" from "anon";

revoke delete on table "temp"."tweets_1378862677871751174" from "authenticated";

revoke insert on table "temp"."tweets_1378862677871751174" from "authenticated";

revoke references on table "temp"."tweets_1378862677871751174" from "authenticated";

revoke select on table "temp"."tweets_1378862677871751174" from "authenticated";

revoke trigger on table "temp"."tweets_1378862677871751174" from "authenticated";

revoke truncate on table "temp"."tweets_1378862677871751174" from "authenticated";

revoke update on table "temp"."tweets_1378862677871751174" from "authenticated";

revoke delete on table "temp"."tweets_1378862677871751174" from "service_role";

revoke insert on table "temp"."tweets_1378862677871751174" from "service_role";

revoke references on table "temp"."tweets_1378862677871751174" from "service_role";

revoke select on table "temp"."tweets_1378862677871751174" from "service_role";

revoke trigger on table "temp"."tweets_1378862677871751174" from "service_role";

revoke truncate on table "temp"."tweets_1378862677871751174" from "service_role";

revoke update on table "temp"."tweets_1378862677871751174" from "service_role";

revoke delete on table "temp"."tweets_316970336" from "anon";

revoke insert on table "temp"."tweets_316970336" from "anon";

revoke references on table "temp"."tweets_316970336" from "anon";

revoke select on table "temp"."tweets_316970336" from "anon";

revoke trigger on table "temp"."tweets_316970336" from "anon";

revoke truncate on table "temp"."tweets_316970336" from "anon";

revoke update on table "temp"."tweets_316970336" from "anon";

revoke delete on table "temp"."tweets_316970336" from "authenticated";

revoke insert on table "temp"."tweets_316970336" from "authenticated";

revoke references on table "temp"."tweets_316970336" from "authenticated";

revoke select on table "temp"."tweets_316970336" from "authenticated";

revoke trigger on table "temp"."tweets_316970336" from "authenticated";

revoke truncate on table "temp"."tweets_316970336" from "authenticated";

revoke update on table "temp"."tweets_316970336" from "authenticated";

revoke delete on table "temp"."tweets_316970336" from "service_role";

revoke insert on table "temp"."tweets_316970336" from "service_role";

revoke references on table "temp"."tweets_316970336" from "service_role";

revoke select on table "temp"."tweets_316970336" from "service_role";

revoke trigger on table "temp"."tweets_316970336" from "service_role";

revoke truncate on table "temp"."tweets_316970336" from "service_role";

revoke update on table "temp"."tweets_316970336" from "service_role";

revoke delete on table "temp"."user_mentions_1038586640" from "anon";

revoke insert on table "temp"."user_mentions_1038586640" from "anon";

revoke references on table "temp"."user_mentions_1038586640" from "anon";

revoke select on table "temp"."user_mentions_1038586640" from "anon";

revoke trigger on table "temp"."user_mentions_1038586640" from "anon";

revoke truncate on table "temp"."user_mentions_1038586640" from "anon";

revoke update on table "temp"."user_mentions_1038586640" from "anon";

revoke delete on table "temp"."user_mentions_1038586640" from "authenticated";

revoke insert on table "temp"."user_mentions_1038586640" from "authenticated";

revoke references on table "temp"."user_mentions_1038586640" from "authenticated";

revoke select on table "temp"."user_mentions_1038586640" from "authenticated";

revoke trigger on table "temp"."user_mentions_1038586640" from "authenticated";

revoke truncate on table "temp"."user_mentions_1038586640" from "authenticated";

revoke update on table "temp"."user_mentions_1038586640" from "authenticated";

revoke delete on table "temp"."user_mentions_1038586640" from "service_role";

revoke insert on table "temp"."user_mentions_1038586640" from "service_role";

revoke references on table "temp"."user_mentions_1038586640" from "service_role";

revoke select on table "temp"."user_mentions_1038586640" from "service_role";

revoke trigger on table "temp"."user_mentions_1038586640" from "service_role";

revoke truncate on table "temp"."user_mentions_1038586640" from "service_role";

revoke update on table "temp"."user_mentions_1038586640" from "service_role";

revoke delete on table "temp"."user_mentions_1211134623285047297" from "anon";

revoke insert on table "temp"."user_mentions_1211134623285047297" from "anon";

revoke references on table "temp"."user_mentions_1211134623285047297" from "anon";

revoke select on table "temp"."user_mentions_1211134623285047297" from "anon";

revoke trigger on table "temp"."user_mentions_1211134623285047297" from "anon";

revoke truncate on table "temp"."user_mentions_1211134623285047297" from "anon";

revoke update on table "temp"."user_mentions_1211134623285047297" from "anon";

revoke delete on table "temp"."user_mentions_1211134623285047297" from "authenticated";

revoke insert on table "temp"."user_mentions_1211134623285047297" from "authenticated";

revoke references on table "temp"."user_mentions_1211134623285047297" from "authenticated";

revoke select on table "temp"."user_mentions_1211134623285047297" from "authenticated";

revoke trigger on table "temp"."user_mentions_1211134623285047297" from "authenticated";

revoke truncate on table "temp"."user_mentions_1211134623285047297" from "authenticated";

revoke update on table "temp"."user_mentions_1211134623285047297" from "authenticated";

revoke delete on table "temp"."user_mentions_1211134623285047297" from "service_role";

revoke insert on table "temp"."user_mentions_1211134623285047297" from "service_role";

revoke references on table "temp"."user_mentions_1211134623285047297" from "service_role";

revoke select on table "temp"."user_mentions_1211134623285047297" from "service_role";

revoke trigger on table "temp"."user_mentions_1211134623285047297" from "service_role";

revoke truncate on table "temp"."user_mentions_1211134623285047297" from "service_role";

revoke update on table "temp"."user_mentions_1211134623285047297" from "service_role";

revoke delete on table "temp"."user_mentions_1378862677871751174" from "anon";

revoke insert on table "temp"."user_mentions_1378862677871751174" from "anon";

revoke references on table "temp"."user_mentions_1378862677871751174" from "anon";

revoke select on table "temp"."user_mentions_1378862677871751174" from "anon";

revoke trigger on table "temp"."user_mentions_1378862677871751174" from "anon";

revoke truncate on table "temp"."user_mentions_1378862677871751174" from "anon";

revoke update on table "temp"."user_mentions_1378862677871751174" from "anon";

revoke delete on table "temp"."user_mentions_1378862677871751174" from "authenticated";

revoke insert on table "temp"."user_mentions_1378862677871751174" from "authenticated";

revoke references on table "temp"."user_mentions_1378862677871751174" from "authenticated";

revoke select on table "temp"."user_mentions_1378862677871751174" from "authenticated";

revoke trigger on table "temp"."user_mentions_1378862677871751174" from "authenticated";

revoke truncate on table "temp"."user_mentions_1378862677871751174" from "authenticated";

revoke update on table "temp"."user_mentions_1378862677871751174" from "authenticated";

revoke delete on table "temp"."user_mentions_1378862677871751174" from "service_role";

revoke insert on table "temp"."user_mentions_1378862677871751174" from "service_role";

revoke references on table "temp"."user_mentions_1378862677871751174" from "service_role";

revoke select on table "temp"."user_mentions_1378862677871751174" from "service_role";

revoke trigger on table "temp"."user_mentions_1378862677871751174" from "service_role";

revoke truncate on table "temp"."user_mentions_1378862677871751174" from "service_role";

revoke update on table "temp"."user_mentions_1378862677871751174" from "service_role";

revoke delete on table "temp"."user_mentions_316970336" from "anon";

revoke insert on table "temp"."user_mentions_316970336" from "anon";

revoke references on table "temp"."user_mentions_316970336" from "anon";

revoke select on table "temp"."user_mentions_316970336" from "anon";

revoke trigger on table "temp"."user_mentions_316970336" from "anon";

revoke truncate on table "temp"."user_mentions_316970336" from "anon";

revoke update on table "temp"."user_mentions_316970336" from "anon";

revoke delete on table "temp"."user_mentions_316970336" from "authenticated";

revoke insert on table "temp"."user_mentions_316970336" from "authenticated";

revoke references on table "temp"."user_mentions_316970336" from "authenticated";

revoke select on table "temp"."user_mentions_316970336" from "authenticated";

revoke trigger on table "temp"."user_mentions_316970336" from "authenticated";

revoke truncate on table "temp"."user_mentions_316970336" from "authenticated";

revoke update on table "temp"."user_mentions_316970336" from "authenticated";

revoke delete on table "temp"."user_mentions_316970336" from "service_role";

revoke insert on table "temp"."user_mentions_316970336" from "service_role";

revoke references on table "temp"."user_mentions_316970336" from "service_role";

revoke select on table "temp"."user_mentions_316970336" from "service_role";

revoke trigger on table "temp"."user_mentions_316970336" from "service_role";

revoke truncate on table "temp"."user_mentions_316970336" from "service_role";

revoke update on table "temp"."user_mentions_316970336" from "service_role";

alter table "temp"."archive_upload_1038586640" drop constraint "archive_upload_1038586640_account_id_archive_at_key";

alter table "temp"."archive_upload_1378862677871751174" drop constraint "archive_upload_1378862677871751174_account_id_archive_at_key";

alter table "temp"."archive_upload_316970336" drop constraint "archive_upload_316970336_account_id_archive_at_key";

alter table "temp"."followers_1038586640" drop constraint "followers_1038586640_account_id_follower_account_id_key";

alter table "temp"."followers_1211134623285047297" drop constraint "followers_1211134623285047297_account_id_follower_account_i_key";

alter table "temp"."followers_1378862677871751174" drop constraint "followers_1378862677871751174_account_id_follower_account_i_key";

alter table "temp"."followers_316970336" drop constraint "followers_316970336_account_id_follower_account_id_key";

alter table "temp"."following_1038586640" drop constraint "following_1038586640_account_id_following_account_id_key";

alter table "temp"."following_1211134623285047297" drop constraint "following_1211134623285047297_account_id_following_account__key";

alter table "temp"."following_1378862677871751174" drop constraint "following_1378862677871751174_account_id_following_account__key";

alter table "temp"."following_316970336" drop constraint "following_316970336_account_id_following_account_id_key";

alter table "temp"."likes_1038586640" drop constraint "likes_1038586640_account_id_liked_tweet_id_key";

alter table "temp"."likes_1211134623285047297" drop constraint "likes_1211134623285047297_account_id_liked_tweet_id_key";

alter table "temp"."likes_1378862677871751174" drop constraint "likes_1378862677871751174_account_id_liked_tweet_id_key";

alter table "temp"."likes_316970336" drop constraint "likes_316970336_account_id_liked_tweet_id_key";

alter table "temp"."profile_1038586640" drop constraint "profile_1038586640_account_id_archive_upload_id_key";

alter table "temp"."profile_1038586640" drop constraint "profile_1038586640_account_id_archive_upload_id_key1";

alter table "temp"."profile_1211134623285047297" drop constraint "profile_1211134623285047297_account_id_archive_upload_id_key";

alter table "temp"."profile_1211134623285047297" drop constraint "profile_1211134623285047297_account_id_archive_upload_id_key1";

alter table "temp"."profile_1378862677871751174" drop constraint "profile_1378862677871751174_account_id_archive_upload_id_key";

alter table "temp"."profile_1378862677871751174" drop constraint "profile_1378862677871751174_account_id_archive_upload_id_key1";

alter table "temp"."profile_316970336" drop constraint "profile_316970336_account_id_archive_upload_id_key";

alter table "temp"."profile_316970336" drop constraint "profile_316970336_account_id_archive_upload_id_key1";

alter table "temp"."tweet_urls_1038586640" drop constraint "tweet_urls_1038586640_tweet_id_url_key";

alter table "temp"."tweet_urls_1211134623285047297" drop constraint "tweet_urls_1211134623285047297_tweet_id_url_key";

alter table "temp"."tweet_urls_1378862677871751174" drop constraint "tweet_urls_1378862677871751174_tweet_id_url_key";

alter table "temp"."tweet_urls_316970336" drop constraint "tweet_urls_316970336_tweet_id_url_key";

alter table "temp"."user_mentions_1038586640" drop constraint "user_mentions_1038586640_mentioned_user_id_tweet_id_key";

alter table "temp"."user_mentions_1211134623285047297" drop constraint "user_mentions_121113462328504729_mentioned_user_id_tweet_id_key";

alter table "temp"."user_mentions_1378862677871751174" drop constraint "user_mentions_137886267787175117_mentioned_user_id_tweet_id_key";

alter table "temp"."user_mentions_316970336" drop constraint "user_mentions_316970336_mentioned_user_id_tweet_id_key";

alter table "temp"."account_1038586640" drop constraint "account_1038586640_pkey";

alter table "temp"."account_1378862677871751174" drop constraint "account_1378862677871751174_pkey";

alter table "temp"."account_316970336" drop constraint "account_316970336_pkey";

alter table "temp"."archive_upload_1038586640" drop constraint "archive_upload_1038586640_pkey";

alter table "temp"."archive_upload_1378862677871751174" drop constraint "archive_upload_1378862677871751174_pkey";

alter table "temp"."archive_upload_316970336" drop constraint "archive_upload_316970336_pkey";

alter table "temp"."followers_1038586640" drop constraint "followers_1038586640_pkey";

alter table "temp"."followers_1211134623285047297" drop constraint "followers_1211134623285047297_pkey";

alter table "temp"."followers_1378862677871751174" drop constraint "followers_1378862677871751174_pkey";

alter table "temp"."followers_316970336" drop constraint "followers_316970336_pkey";

alter table "temp"."following_1038586640" drop constraint "following_1038586640_pkey";

alter table "temp"."following_1211134623285047297" drop constraint "following_1211134623285047297_pkey";

alter table "temp"."following_1378862677871751174" drop constraint "following_1378862677871751174_pkey";

alter table "temp"."following_316970336" drop constraint "following_316970336_pkey";

alter table "temp"."liked_tweets_1038586640" drop constraint "liked_tweets_1038586640_pkey";

alter table "temp"."liked_tweets_1211134623285047297" drop constraint "liked_tweets_1211134623285047297_pkey";

alter table "temp"."liked_tweets_1378862677871751174" drop constraint "liked_tweets_1378862677871751174_pkey";

alter table "temp"."liked_tweets_316970336" drop constraint "liked_tweets_316970336_pkey";

alter table "temp"."likes_1038586640" drop constraint "likes_1038586640_pkey";

alter table "temp"."likes_1211134623285047297" drop constraint "likes_1211134623285047297_pkey";

alter table "temp"."likes_1378862677871751174" drop constraint "likes_1378862677871751174_pkey";

alter table "temp"."likes_316970336" drop constraint "likes_316970336_pkey";

alter table "temp"."mentioned_users_1038586640" drop constraint "mentioned_users_1038586640_pkey";

alter table "temp"."mentioned_users_1211134623285047297" drop constraint "mentioned_users_1211134623285047297_pkey";

alter table "temp"."mentioned_users_1378862677871751174" drop constraint "mentioned_users_1378862677871751174_pkey";

alter table "temp"."mentioned_users_316970336" drop constraint "mentioned_users_316970336_pkey";

alter table "temp"."profile_1038586640" drop constraint "profile_1038586640_pkey";

alter table "temp"."profile_1211134623285047297" drop constraint "profile_1211134623285047297_pkey";

alter table "temp"."profile_1378862677871751174" drop constraint "profile_1378862677871751174_pkey";

alter table "temp"."profile_316970336" drop constraint "profile_316970336_pkey";

alter table "temp"."tweet_media_1038586640" drop constraint "tweet_media_1038586640_pkey";

alter table "temp"."tweet_media_1211134623285047297" drop constraint "tweet_media_1211134623285047297_pkey";

alter table "temp"."tweet_media_1378862677871751174" drop constraint "tweet_media_1378862677871751174_pkey";

alter table "temp"."tweet_media_316970336" drop constraint "tweet_media_316970336_pkey";

alter table "temp"."tweet_urls_1038586640" drop constraint "tweet_urls_1038586640_pkey";

alter table "temp"."tweet_urls_1211134623285047297" drop constraint "tweet_urls_1211134623285047297_pkey";

alter table "temp"."tweet_urls_1378862677871751174" drop constraint "tweet_urls_1378862677871751174_pkey";

alter table "temp"."tweet_urls_316970336" drop constraint "tweet_urls_316970336_pkey";

alter table "temp"."tweets_1038586640" drop constraint "tweets_1038586640_pkey";

alter table "temp"."tweets_1211134623285047297" drop constraint "tweets_1211134623285047297_pkey";

alter table "temp"."tweets_1378862677871751174" drop constraint "tweets_1378862677871751174_pkey";

alter table "temp"."tweets_316970336" drop constraint "tweets_316970336_pkey";

alter table "temp"."user_mentions_1038586640" drop constraint "user_mentions_1038586640_pkey";

alter table "temp"."user_mentions_1211134623285047297" drop constraint "user_mentions_1211134623285047297_pkey";

alter table "temp"."user_mentions_1378862677871751174" drop constraint "user_mentions_1378862677871751174_pkey";

alter table "temp"."user_mentions_316970336" drop constraint "user_mentions_316970336_pkey";

drop index if exists "temp"."account_1038586640_pkey";

drop index if exists "temp"."account_1378862677871751174_pkey";

drop index if exists "temp"."account_316970336_pkey";

drop index if exists "temp"."archive_upload_1038586640_account_id_archive_at_key";

drop index if exists "temp"."archive_upload_1038586640_account_id_idx";

drop index if exists "temp"."archive_upload_1038586640_pkey";

drop index if exists "temp"."archive_upload_1378862677871751174_account_id_archive_at_key";

drop index if exists "temp"."archive_upload_1378862677871751174_account_id_idx";

drop index if exists "temp"."archive_upload_1378862677871751174_pkey";

drop index if exists "temp"."archive_upload_316970336_account_id_archive_at_key";

drop index if exists "temp"."archive_upload_316970336_account_id_idx";

drop index if exists "temp"."archive_upload_316970336_pkey";

drop index if exists "temp"."followers_1038586640_account_id_follower_account_id_key";

drop index if exists "temp"."followers_1038586640_account_id_idx";

drop index if exists "temp"."followers_1038586640_archive_upload_id_idx";

drop index if exists "temp"."followers_1038586640_pkey";

drop index if exists "temp"."followers_1211134623285047297_account_id_follower_account_i_key";

drop index if exists "temp"."followers_1211134623285047297_account_id_idx";

drop index if exists "temp"."followers_1211134623285047297_archive_upload_id_idx";

drop index if exists "temp"."followers_1211134623285047297_pkey";

drop index if exists "temp"."followers_1378862677871751174_account_id_follower_account_i_key";

drop index if exists "temp"."followers_1378862677871751174_account_id_idx";

drop index if exists "temp"."followers_1378862677871751174_archive_upload_id_idx";

drop index if exists "temp"."followers_1378862677871751174_pkey";

drop index if exists "temp"."followers_316970336_account_id_follower_account_id_key";

drop index if exists "temp"."followers_316970336_account_id_idx";

drop index if exists "temp"."followers_316970336_archive_upload_id_idx";

drop index if exists "temp"."followers_316970336_pkey";

drop index if exists "temp"."following_1038586640_account_id_following_account_id_key";

drop index if exists "temp"."following_1038586640_account_id_idx";

drop index if exists "temp"."following_1038586640_archive_upload_id_idx";

drop index if exists "temp"."following_1038586640_pkey";

drop index if exists "temp"."following_1211134623285047297_account_id_following_account__key";

drop index if exists "temp"."following_1211134623285047297_account_id_idx";

drop index if exists "temp"."following_1211134623285047297_archive_upload_id_idx";

drop index if exists "temp"."following_1211134623285047297_pkey";

drop index if exists "temp"."following_1378862677871751174_account_id_following_account__key";

drop index if exists "temp"."following_1378862677871751174_account_id_idx";

drop index if exists "temp"."following_1378862677871751174_archive_upload_id_idx";

drop index if exists "temp"."following_1378862677871751174_pkey";

drop index if exists "temp"."following_316970336_account_id_following_account_id_key";

drop index if exists "temp"."following_316970336_account_id_idx";

drop index if exists "temp"."following_316970336_archive_upload_id_idx";

drop index if exists "temp"."following_316970336_pkey";

drop index if exists "temp"."liked_tweets_1038586640_pkey";

drop index if exists "temp"."liked_tweets_1211134623285047297_pkey";

drop index if exists "temp"."liked_tweets_1378862677871751174_pkey";

drop index if exists "temp"."liked_tweets_316970336_pkey";

drop index if exists "temp"."likes_1038586640_account_id_idx";

drop index if exists "temp"."likes_1038586640_account_id_liked_tweet_id_key";

drop index if exists "temp"."likes_1038586640_archive_upload_id_idx";

drop index if exists "temp"."likes_1038586640_liked_tweet_id_idx";

drop index if exists "temp"."likes_1038586640_pkey";

drop index if exists "temp"."likes_1211134623285047297_account_id_idx";

drop index if exists "temp"."likes_1211134623285047297_account_id_liked_tweet_id_key";

drop index if exists "temp"."likes_1211134623285047297_archive_upload_id_idx";

drop index if exists "temp"."likes_1211134623285047297_liked_tweet_id_idx";

drop index if exists "temp"."likes_1211134623285047297_pkey";

drop index if exists "temp"."likes_1378862677871751174_account_id_idx";

drop index if exists "temp"."likes_1378862677871751174_account_id_liked_tweet_id_key";

drop index if exists "temp"."likes_1378862677871751174_archive_upload_id_idx";

drop index if exists "temp"."likes_1378862677871751174_liked_tweet_id_idx";

drop index if exists "temp"."likes_1378862677871751174_pkey";

drop index if exists "temp"."likes_316970336_account_id_idx";

drop index if exists "temp"."likes_316970336_account_id_liked_tweet_id_key";

drop index if exists "temp"."likes_316970336_archive_upload_id_idx";

drop index if exists "temp"."likes_316970336_liked_tweet_id_idx";

drop index if exists "temp"."likes_316970336_pkey";

drop index if exists "temp"."mentioned_users_1038586640_pkey";

drop index if exists "temp"."mentioned_users_1211134623285047297_pkey";

drop index if exists "temp"."mentioned_users_1378862677871751174_pkey";

drop index if exists "temp"."mentioned_users_316970336_pkey";

drop index if exists "temp"."profile_1038586640_account_id_archive_upload_id_key";

drop index if exists "temp"."profile_1038586640_account_id_archive_upload_id_key1";

drop index if exists "temp"."profile_1038586640_account_id_idx";

drop index if exists "temp"."profile_1038586640_archive_upload_id_idx";

drop index if exists "temp"."profile_1038586640_pkey";

drop index if exists "temp"."profile_1211134623285047297_account_id_archive_upload_id_key";

drop index if exists "temp"."profile_1211134623285047297_account_id_archive_upload_id_key1";

drop index if exists "temp"."profile_1211134623285047297_account_id_idx";

drop index if exists "temp"."profile_1211134623285047297_archive_upload_id_idx";

drop index if exists "temp"."profile_1211134623285047297_pkey";

drop index if exists "temp"."profile_1378862677871751174_account_id_archive_upload_id_key";

drop index if exists "temp"."profile_1378862677871751174_account_id_archive_upload_id_key1";

drop index if exists "temp"."profile_1378862677871751174_account_id_idx";

drop index if exists "temp"."profile_1378862677871751174_archive_upload_id_idx";

drop index if exists "temp"."profile_1378862677871751174_pkey";

drop index if exists "temp"."profile_316970336_account_id_archive_upload_id_key";

drop index if exists "temp"."profile_316970336_account_id_archive_upload_id_key1";

drop index if exists "temp"."profile_316970336_account_id_idx";

drop index if exists "temp"."profile_316970336_archive_upload_id_idx";

drop index if exists "temp"."profile_316970336_pkey";

drop index if exists "temp"."tweet_media_1038586640_archive_upload_id_idx";

drop index if exists "temp"."tweet_media_1038586640_pkey";

drop index if exists "temp"."tweet_media_1038586640_tweet_id_idx";

drop index if exists "temp"."tweet_media_1211134623285047297_archive_upload_id_idx";

drop index if exists "temp"."tweet_media_1211134623285047297_pkey";

drop index if exists "temp"."tweet_media_1211134623285047297_tweet_id_idx";

drop index if exists "temp"."tweet_media_1378862677871751174_archive_upload_id_idx";

drop index if exists "temp"."tweet_media_1378862677871751174_pkey";

drop index if exists "temp"."tweet_media_1378862677871751174_tweet_id_idx";

drop index if exists "temp"."tweet_media_316970336_archive_upload_id_idx";

drop index if exists "temp"."tweet_media_316970336_pkey";

drop index if exists "temp"."tweet_media_316970336_tweet_id_idx";

drop index if exists "temp"."tweet_urls_1038586640_pkey";

drop index if exists "temp"."tweet_urls_1038586640_tweet_id_idx";

drop index if exists "temp"."tweet_urls_1038586640_tweet_id_url_key";

drop index if exists "temp"."tweet_urls_1211134623285047297_pkey";

drop index if exists "temp"."tweet_urls_1211134623285047297_tweet_id_idx";

drop index if exists "temp"."tweet_urls_1211134623285047297_tweet_id_url_key";

drop index if exists "temp"."tweet_urls_1378862677871751174_pkey";

drop index if exists "temp"."tweet_urls_1378862677871751174_tweet_id_idx";

drop index if exists "temp"."tweet_urls_1378862677871751174_tweet_id_url_key";

drop index if exists "temp"."tweet_urls_316970336_pkey";

drop index if exists "temp"."tweet_urls_316970336_tweet_id_idx";

drop index if exists "temp"."tweet_urls_316970336_tweet_id_url_key";

drop index if exists "temp"."tweets_1038586640_account_id_idx";

drop index if exists "temp"."tweets_1038586640_archive_upload_id_idx";

drop index if exists "temp"."tweets_1038586640_created_at_idx";

drop index if exists "temp"."tweets_1038586640_fts_idx";

drop index if exists "temp"."tweets_1038586640_pkey";

drop index if exists "temp"."tweets_1211134623285047297_account_id_idx";

drop index if exists "temp"."tweets_1211134623285047297_archive_upload_id_idx";

drop index if exists "temp"."tweets_1211134623285047297_fts_idx";

drop index if exists "temp"."tweets_1211134623285047297_pkey";

drop index if exists "temp"."tweets_1378862677871751174_account_id_idx";

drop index if exists "temp"."tweets_1378862677871751174_archive_upload_id_idx";

drop index if exists "temp"."tweets_1378862677871751174_created_at_idx";

drop index if exists "temp"."tweets_1378862677871751174_fts_idx";

drop index if exists "temp"."tweets_1378862677871751174_pkey";

drop index if exists "temp"."tweets_316970336_account_id_idx";

drop index if exists "temp"."tweets_316970336_archive_upload_id_idx";

drop index if exists "temp"."tweets_316970336_created_at_idx";

drop index if exists "temp"."tweets_316970336_fts_idx";

drop index if exists "temp"."tweets_316970336_pkey";

drop index if exists "temp"."user_mentions_1038586640_mentioned_user_id_idx";

drop index if exists "temp"."user_mentions_1038586640_mentioned_user_id_tweet_id_key";

drop index if exists "temp"."user_mentions_1038586640_pkey";

drop index if exists "temp"."user_mentions_1038586640_tweet_id_idx";

drop index if exists "temp"."user_mentions_1211134623285047297_mentioned_user_id_idx";

drop index if exists "temp"."user_mentions_1211134623285047297_pkey";

drop index if exists "temp"."user_mentions_1211134623285047297_tweet_id_idx";

drop index if exists "temp"."user_mentions_121113462328504729_mentioned_user_id_tweet_id_key";

drop index if exists "temp"."user_mentions_1378862677871751174_mentioned_user_id_idx";

drop index if exists "temp"."user_mentions_1378862677871751174_pkey";

drop index if exists "temp"."user_mentions_1378862677871751174_tweet_id_idx";

drop index if exists "temp"."user_mentions_137886267787175117_mentioned_user_id_tweet_id_key";

drop index if exists "temp"."user_mentions_316970336_mentioned_user_id_idx";

drop index if exists "temp"."user_mentions_316970336_mentioned_user_id_tweet_id_key";

drop index if exists "temp"."user_mentions_316970336_pkey";

drop index if exists "temp"."user_mentions_316970336_tweet_id_idx";

drop table "temp"."account_1038586640";

drop table "temp"."account_1378862677871751174";

drop table "temp"."account_316970336";

drop table "temp"."archive_upload_1038586640";

drop table "temp"."archive_upload_1378862677871751174";

drop table "temp"."archive_upload_316970336";

drop table "temp"."followers_1038586640";

drop table "temp"."followers_1211134623285047297";

drop table "temp"."followers_1378862677871751174";

drop table "temp"."followers_316970336";

drop table "temp"."following_1038586640";

drop table "temp"."following_1211134623285047297";

drop table "temp"."following_1378862677871751174";

drop table "temp"."following_316970336";

drop table "temp"."liked_tweets_1038586640";

drop table "temp"."liked_tweets_1211134623285047297";

drop table "temp"."liked_tweets_1378862677871751174";

drop table "temp"."liked_tweets_316970336";

drop table "temp"."likes_1038586640";

drop table "temp"."likes_1211134623285047297";

drop table "temp"."likes_1378862677871751174";

drop table "temp"."likes_316970336";

drop table "temp"."mentioned_users_1038586640";

drop table "temp"."mentioned_users_1211134623285047297";

drop table "temp"."mentioned_users_1378862677871751174";

drop table "temp"."mentioned_users_316970336";

drop table "temp"."profile_1038586640";

drop table "temp"."profile_1211134623285047297";

drop table "temp"."profile_1378862677871751174";

drop table "temp"."profile_316970336";

drop table "temp"."tweet_media_1038586640";

drop table "temp"."tweet_media_1211134623285047297";

drop table "temp"."tweet_media_1378862677871751174";

drop table "temp"."tweet_media_316970336";

drop table "temp"."tweet_urls_1038586640";

drop table "temp"."tweet_urls_1211134623285047297";

drop table "temp"."tweet_urls_1378862677871751174";

drop table "temp"."tweet_urls_316970336";

drop table "temp"."tweets_1038586640";

drop table "temp"."tweets_1211134623285047297";

drop table "temp"."tweets_1378862677871751174";

drop table "temp"."tweets_316970336";

drop table "temp"."user_mentions_1038586640";

drop table "temp"."user_mentions_1211134623285047297";

drop table "temp"."user_mentions_1378862677871751174";

drop table "temp"."user_mentions_316970336";


set check_function_bodies = off;

CREATE OR REPLACE FUNCTION tes.hash_user_id(user_id text)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- Convert the input to text if not already, hash it using SHA-256,
    -- and return as a hex string
    RETURN encode(digest(user_id::text, 'sha256'), 'hex');
EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Error hashing user_id: %', SQLERRM;
END;
$function$
;


