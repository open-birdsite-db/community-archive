DROP FUNCTION IF EXISTS tes.get_followings;

CREATE OR REPLACE FUNCTION tes.get_followings()
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
        f2.following_account_id AS account_id,
        mu.screen_name AS username
    FROM public.following f2
    LEFT JOIN mentioned_users mu ON mu.user_id = f2.following_account_id
    WHERE f2.account_id = v_account_id and mu.screen_name is not null;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;