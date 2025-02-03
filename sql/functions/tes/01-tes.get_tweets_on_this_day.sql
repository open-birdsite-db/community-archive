DROP FUNCTION IF EXISTS tes.get_tweets_on_this_day;

CREATE OR REPLACE FUNCTION tes.get_tweets_on_this_day(
    p_limit INTEGER DEFAULT NULL
)
RETURNS TABLE (
    tweet_id TEXT,
    account_id TEXT,
    created_at TIMESTAMP WITH TIME ZONE,
    full_text TEXT,
    retweet_count INTEGER,
    favorite_count INTEGER,
    reply_to_tweet_id TEXT,
    reply_to_user_id TEXT,
    reply_to_username TEXT,
    username TEXT,
    account_display_name TEXT,
    avatar_media_url TEXT
) AS $$
DECLARE
    current_month INTEGER;
    current_day INTEGER;
    v_account_id TEXT;
BEGIN
    -- Get the current user's account_id
    v_account_id := tes.get_current_account_id();

    -- Get the current month and day
    SELECT EXTRACT(MONTH FROM CURRENT_DATE), EXTRACT(DAY FROM CURRENT_DATE)
    INTO current_month, current_day;

    RETURN QUERY
    SELECT 
        t.tweet_id, t.account_id, t.created_at, t.full_text, t.retweet_count,
        t.favorite_count, t.reply_to_tweet_id, t.reply_to_user_id, t.reply_to_username,
        a.username, a.account_display_name, p.avatar_media_url
    FROM 
        public.tweets t
        inner join account a on t.account_id = a.account_id
        inner join profile p on t.account_id = p.account_id
    WHERE 
        EXTRACT(MONTH FROM t.created_at AT TIME ZONE 'UTC') = current_month
        AND EXTRACT(DAY FROM t.created_at AT TIME ZONE 'UTC') = current_day
        AND EXTRACT(YEAR FROM t.created_at AT TIME ZONE 'UTC') < EXTRACT(YEAR FROM CURRENT_DATE)
        AND t.account_id = v_account_id
    ORDER BY 
        t.favorite_count DESC, t.retweet_count DESC
    LIMIT p_limit;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;