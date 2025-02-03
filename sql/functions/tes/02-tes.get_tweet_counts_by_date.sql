DROP FUNCTION IF EXISTS tes.get_tweet_counts_by_date;

CREATE OR REPLACE FUNCTION tes.get_tweet_counts_by_date()
RETURNS TABLE (tweet_date DATE, tweet_count BIGINT) AS $$
DECLARE
    v_account_id TEXT;
BEGIN
    -- Get the current user's account_id
    v_account_id := tes.get_current_account_id();

    RETURN QUERY
    SELECT 
        DATE(created_at) AS tweet_date,
        COUNT(*) AS tweet_count
    FROM 
        public.tweets
    WHERE 
        account_id = v_account_id
    GROUP BY 
        DATE(created_at)
    ORDER BY 
        tweet_date;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;