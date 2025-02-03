DROP FUNCTION IF EXISTS tes.get_followers;

CREATE OR REPLACE FUNCTION tes.get_followers()
RETURNS TABLE (
    account_id TEXT,
    username TEXT
) AS $$
DECLARE
    v_account_id TEXT;
BEGIN
    -- Get the current user's account_id
    v_account_id := tes.get_current_account_id();

    RETURN QUERY
    SELECT 
        f1.follower_account_id AS account_id,
        mu.screen_name AS username
    FROM public.followers f1
    LEFT JOIN mentioned_users mu ON mu.user_id = f1.follower_account_id
    WHERE f1.account_id = v_account_id and mu.screen_name is not null;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

