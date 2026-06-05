-- ============================================================================
-- Fix: activity feed is one-directional between friends
-- ============================================================================
--
-- SYMPTOM
--   In a pair of friends, only ONE of them could see the other's "recent
--   activity". Example: احمد (@A) saw Yazeed's (@bulldozer) sessions, but
--   Yazeed saw only his own — احمد's sessions never appeared in Yazeed's feed.
--
-- ROOT CAUSE
--   A friendship is stored as a SINGLE row: (user_id = requester,
--   friend_id = the other person). The old SELECT policy on activity_feed
--   only matched ONE direction of that row:
--
--       EXISTS (SELECT 1 FROM friendships
--               WHERE friendships.user_id  = auth.uid()              -- me = requester
--                 AND friendships.friend_id = activity_feed.user_id  -- author = friend
--                 AND status = 'accepted')
--
--   So only the person sitting in the friendship's `user_id` column (the one
--   who SENT the request) could read the other's activity. The person in
--   `friend_id` (who ACCEPTED) was blocked. activity_feed was the only table
--   left with this asymmetry — sessions / working_weights / programmes were
--   already fixed to check BOTH directions. This migration brings activity_feed
--   in line with them.
--
-- FIX
--   Replace the policy with the same both-directions predicate used by the
--   other friend-readable tables.
-- ============================================================================

DROP POLICY IF EXISTS "Friends can view activity" ON public.activity_feed;

CREATE POLICY "Friends can view activity"
  ON public.activity_feed
  FOR SELECT
  USING (
    (auth.uid() = user_id)
    OR EXISTS (
      SELECT 1
      FROM public.friendships
      WHERE (
              ((friendships.user_id  = auth.uid())            AND (friendships.friend_id = activity_feed.user_id))
           OR ((friendships.user_id  = activity_feed.user_id) AND (friendships.friend_id = auth.uid()))
            )
        AND friendships.status = 'accepted'
    )
  );
