DROP FUNCTION IF EXISTS tes_get_followers;
CREATE OR REPLACE FUNCTION tes_get_followers(user_id TEXT)
RETURNS TABLE (
    account_id TEXT,
    username TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        f1.follower_account_id AS account_id,
        mu.screen_name AS username
    FROM public.followers f1
    LEFT JOIN mentioned_users mu ON mu.user_id = f1.follower_account_id
    WHERE f1.account_id = $1 and mu.screen_name is not null;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION tes_get_followings(user_id TEXT)
RETURNS TABLE (
    account_id TEXT,
    username TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        f2.following_account_id AS account_id,
        mu.screen_name AS username
    FROM public.following f2
    LEFT JOIN mentioned_users mu ON mu.user_id = f2.following_account_id
    WHERE f2.account_id = $1 and mu.screen_name is not null;  
END;
$$ LANGUAGE plpgsql;