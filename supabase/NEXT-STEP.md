# Supabase connection checklist

No Supabase project has been created yet. The connected account currently contains the organization `stocklabmulti's Org`.

Before creating a project, confirm that this is the intended organization and select the desired region. Singapore (`ap-southeast-1`) is the nearest available region for Indonesia in the current region list.

The draft SQL in `draft-schema.sql` has not been applied. It is a starting point only; membership, private bidding, action validation, and game-state transitions require additional transaction-safe RPC functions before public play.

Frontend configuration may contain the project URL and publishable key only. Never commit a secret/service-role key.
