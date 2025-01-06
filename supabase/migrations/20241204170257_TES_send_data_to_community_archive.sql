-- Modify tweets table
ALTER TABLE public.tweets DROP CONSTRAINT IF EXISTS tweets_archive_upload_id_fkey;
ALTER TABLE public.tweets ALTER COLUMN archive_upload_id DROP NOT NULL;
ALTER TABLE public.tweets 
ADD CONSTRAINT tweets_archive_upload_id_fkey 
FOREIGN KEY (archive_upload_id) 
REFERENCES public.archive_upload (id);

-- Modify profile table
ALTER TABLE public.profile DROP CONSTRAINT IF EXISTS profile_archive_upload_id_fkey;
ALTER TABLE public.profile ALTER COLUMN archive_upload_id DROP NOT NULL;
ALTER TABLE public.profile 
ADD CONSTRAINT profile_archive_upload_id_fkey 
FOREIGN KEY (archive_upload_id) 
REFERENCES public.archive_upload (id);

-- Modify followers table
ALTER TABLE public.followers DROP CONSTRAINT IF EXISTS followers_archive_upload_id_fkey;
ALTER TABLE public.followers ALTER COLUMN archive_upload_id DROP NOT NULL;
ALTER TABLE public.followers 
ADD CONSTRAINT followers_archive_upload_id_fkey 
FOREIGN KEY (archive_upload_id) 
REFERENCES public.archive_upload (id);

-- Modify following table
ALTER TABLE public.following DROP CONSTRAINT IF EXISTS following_archive_upload_id_fkey;
ALTER TABLE public.following ALTER COLUMN archive_upload_id DROP NOT NULL;
ALTER TABLE public.following 
ADD CONSTRAINT following_archive_upload_id_fkey 
FOREIGN KEY (archive_upload_id) 
REFERENCES public.archive_upload (id);

-- Modify likes table
ALTER TABLE public.likes DROP CONSTRAINT IF EXISTS likes_archive_upload_id_fkey;
ALTER TABLE public.likes ALTER COLUMN archive_upload_id DROP NOT NULL;
ALTER TABLE public.likes 
ADD CONSTRAINT likes_archive_upload_id_fkey 
FOREIGN KEY (archive_upload_id) 
REFERENCES public.archive_upload (id);

-- Modify tweet_media table
ALTER TABLE public.tweet_media DROP CONSTRAINT IF EXISTS tweet_media_archive_upload_id_fkey;
ALTER TABLE public.tweet_media ALTER COLUMN archive_upload_id DROP NOT NULL;
ALTER TABLE public.tweet_media 
ADD CONSTRAINT tweet_media_archive_upload_id_fkey 
FOREIGN KEY (archive_upload_id) 
REFERENCES public.archive_upload (id);

-- add updated_at column to tables

-- First create the trigger function if it doesn't exist
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Add updated_at column and trigger to tweets table
ALTER TABLE public.tweets 
ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP;

DROP TRIGGER IF EXISTS update_tweets_updated_at ON public.tweets;
CREATE TRIGGER update_tweets_updated_at 
    BEFORE UPDATE ON public.tweets 
    FOR EACH ROW 
    EXECUTE FUNCTION update_updated_at_column();

-- Add updated_at column and trigger to profile table
ALTER TABLE public.profile 
ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP;

DROP TRIGGER IF EXISTS update_profile_updated_at ON public.profile;
CREATE TRIGGER update_profile_updated_at 
    BEFORE UPDATE ON public.profile 
    FOR EACH ROW 
    EXECUTE FUNCTION update_updated_at_column();

-- Add updated_at column and trigger to account table
ALTER TABLE public.account 
ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP;

DROP TRIGGER IF EXISTS update_account_updated_at ON public.account;
CREATE TRIGGER update_account_updated_at 
    BEFORE UPDATE ON public.account 
    FOR EACH ROW 
    EXECUTE FUNCTION update_updated_at_column();

-- Add updated_at column and trigger to followers table
ALTER TABLE public.followers 
ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP;

DROP TRIGGER IF EXISTS update_followers_updated_at ON public.followers;
CREATE TRIGGER update_followers_updated_at 
    BEFORE UPDATE ON public.followers 
    FOR EACH ROW 
    EXECUTE FUNCTION update_updated_at_column();

-- Add updated_at column and trigger to following table
ALTER TABLE public.following 
ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP;

DROP TRIGGER IF EXISTS update_following_updated_at ON public.following;
CREATE TRIGGER update_following_updated_at 
    BEFORE UPDATE ON public.following 
    FOR EACH ROW 
    EXECUTE FUNCTION update_updated_at_column();

-- Add updated_at column and trigger to likes table
ALTER TABLE public.likes 
ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP;

DROP TRIGGER IF EXISTS update_likes_updated_at ON public.likes;
CREATE TRIGGER update_likes_updated_at 
    BEFORE UPDATE ON public.likes 
    FOR EACH ROW 
    EXECUTE FUNCTION update_updated_at_column();

-- Add updated_at column and trigger to tweet_media table
ALTER TABLE public.tweet_media 
ADD COLUMN IF NOT EXISTS updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP;

DROP TRIGGER IF EXISTS update_tweet_media_updated_at ON public.tweet_media;
CREATE TRIGGER update_tweet_media_updated_at 
    BEFORE UPDATE ON public.tweet_media 
    FOR EACH ROW 
    EXECUTE FUNCTION update_updated_at_column();


-- table to disable users from sending live data to the community archive
CREATE TABLE IF NOT EXISTS public.tes_blocked_scraping_users (
    account_id TEXT PRIMARY KEY ,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);


CREATE TRIGGER update_tes_blocked_scraping_timestamp
    BEFORE UPDATE ON public.tes_blocked_scraping_users
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();


-- Enable RLS
ALTER TABLE public.tes_blocked_scraping_users ENABLE ROW LEVEL SECURITY;

-- Drop existing policies if they exist
DROP POLICY IF EXISTS "Allow select for all" ON public.tes_blocked_scraping_users;

-- Create read-only policy for authenticated and anonymous users
CREATE POLICY "Allow select for all" 
ON public.tes_blocked_scraping_users
FOR SELECT 
TO public
USING (true);




--create bucket
insert into storage.buckets (id, name,public) values  
('twitter_api_files', 'twitter_api_files',false);


CREATE TABLE IF NOT EXISTS temporary_data (
    type VARCHAR(255) NOT NULL,
    item_id VARCHAR(255) NOT NULL,
    originator_id VARCHAR(255) NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    data JSONB NOT NULL,
    user_id VARCHAR(255) NOT NULL DEFAULT 'anon',
    inserted TIMESTAMP WITH TIME ZONE,
    stored boolean DEFAULT false,
    PRIMARY KEY (type, originator_id, item_id, timestamp)
);



CREATE OR REPLACE FUNCTION private.tes_process_account_records()
RETURNS TABLE (
    processed INTEGER,
    errors TEXT[]
) AS $$
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
            INSERT INTO public.account
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
                created_via = EXCLUDED.created_via,
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
$$ LANGUAGE plpgsql;




CREATE OR REPLACE FUNCTION private.tes_process_profile_records()
RETURNS TABLE (
    processed INTEGER,
    errors TEXT[]
) AS $$
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
            INSERT INTO public.profile (
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
            ON CONFLICT (account_id, archive_upload_id) 
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
$$ LANGUAGE plpgsql;




CREATE OR REPLACE FUNCTION private.tes_process_tweet_records()
RETURNS TABLE (
    processed INTEGER,
    errors TEXT[]
) AS $$
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
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION private.tes_process_media_records()
RETURNS TABLE (
    processed INTEGER,
    errors TEXT[]
) AS $$
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
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION private.tes_process_url_records()
RETURNS TABLE (
    processed INTEGER,
    errors TEXT[]
) AS $$
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
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION private.tes_process_mention_records()
RETURNS TABLE (
    processed INTEGER,
    errors TEXT[]
) AS $$
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
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION private.tes_complete_group_insertions()
RETURNS TABLE (
    completed INTEGER,
    errors TEXT[]
) AS $$
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
$$ LANGUAGE plpgsql;




CREATE OR REPLACE FUNCTION private.tes_import_temporary_data_into_tables()
RETURNS void AS $$
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
$$ LANGUAGE plpgsql;





CREATE OR REPLACE FUNCTION private.tes_invoke_edge_function_move_data_to_storage()
RETURNS void AS $$
DECLARE
    request_id TEXT;
    response_status INTEGER;
    start_time TIMESTAMP;
    elapsed_seconds NUMERIC;
BEGIN
    -- First execution
    SELECT status, clock_timestamp() INTO response_status, start_time FROM net.http_post(
        url:='https://fabxmporizzqflnftavs.supabase.co/functions/v1/schedule_data_moving'
    );

END;
$$ LANGUAGE plpgsql;

-- Enable pg_cron extension if not already enabled
CREATE EXTENSION IF NOT EXISTS pg_net;

select
  cron.schedule(
    'tes-invoke-edge-function-scheduler',
    '* * * * *', 
    $$
    select private.tes_invoke_edge_function_move_data_to_storage()
    $$
  );


-- Schedule job to run every 5 minutes
SELECT cron.schedule('tes-insert-temporary-data-into-tables', 
    '*/5 * * * *', $$SELECT private.tes_import_temporary_data_into_tables();$$);
