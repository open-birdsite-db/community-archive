DROP FUNCTION IF EXISTS tes.get_moots;

CREATE OR REPLACE FUNCTION tes.get_moots()
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
        f1.follower_account_id as account_id,
        mu.screen_name as username
    FROM public.followers f1
    INNER JOIN public.following f2 
        ON f1.account_id = f2.account_id 
        AND f1.follower_account_id = f2.following_account_id
    left join mentioned_users mu on mu.user_id = f1.follower_account_id
    where f1.account_id = v_account_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;