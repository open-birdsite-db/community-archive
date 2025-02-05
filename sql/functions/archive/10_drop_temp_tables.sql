CREATE OR REPLACE FUNCTION public.drop_temp_tables(p_suffix TEXT)
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

    -- Check if the user is authenticated or is the postgres/service_role
    IF auth.uid() IS NULL AND current_user NOT IN ('postgres', 'service_role') THEN
        RAISE EXCEPTION 'Not authenticated';
    END IF;

    RAISE NOTICE 'drop_temp_tables called with suffix: %', p_suffix;

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
$$ LANGUAGE plpgsql SECURITY DEFINER;
