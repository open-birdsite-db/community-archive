CREATE OR REPLACE FUNCTION public.insert_temp_tweets(p_tweets JSONB, p_suffix TEXT)
RETURNS VOID AS $$
DECLARE
    v_provider_id TEXT;
BEGIN
    -- Get provider_id from JWT
    SELECT ((auth.jwt()->'app_metadata'->>'provider_id')::text) INTO v_provider_id;
    
    -- Verify the JWT provider_id matches the suffix
    IF current_user NOT IN ('postgres', 'service_role') AND (v_provider_id IS NULL OR v_provider_id != p_suffix) THEN
        RAISE EXCEPTION 'Unauthorized: provider_id % does not match account_id %', v_provider_id, p_suffix;
    END IF;

    IF auth.uid() IS NULL AND current_user NOT IN ('postgres', 'service_role') THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    EXECUTE format('
    INSERT INTO temp.tweets_%s (
        tweet_id, account_id, created_at, full_text, retweet_count, favorite_count,
        reply_to_tweet_id, reply_to_user_id, reply_to_username, archive_upload_id
    )
    SELECT
        (tweet->>''id_str'')::TEXT,
        (tweet->>''user_id'')::TEXT,
        (tweet->>''created_at'')::TIMESTAMP WITH TIME ZONE,
        (tweet->>''full_text'')::TEXT,
        (tweet->>''retweet_count'')::INTEGER,
        (tweet->>''favorite_count'')::INTEGER,
        (tweet->>''in_reply_to_status_id_str'')::TEXT,
        (tweet->>''in_reply_to_user_id_str'')::TEXT,
        (tweet->>''in_reply_to_screen_name'')::TEXT,
        -1
    FROM jsonb_array_elements($1) AS tweet
    ', p_suffix)
    USING p_tweets;
    RAISE NOTICE 'insert_temp_tweets called with suffix: %', p_suffix;

END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
