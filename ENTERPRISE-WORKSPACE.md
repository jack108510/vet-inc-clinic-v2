# Enterprise pricing workspace (live backend)

**Page:** `group-control.html` / `enterprise-app.js` on GitHub Pages. **Database:** existing Clinic IQ Supabase project `rnqhhzatlxmyvccdvqkr`.

## What is live

- Supabase Auth login via password or email sign-in link. The app stores the session in tab-scoped sessionStorage, refreshes it, and sends the user's JWT to PostgREST. The browser contains only the **public anon key**, never the service-role or management key.
- Private enterprise organizations, members/roles, changes, actual proposed service prices, included location names, work items, approval decisions, and action records are persisted in dedicated `enterprise_*` tables.
- Read access uses row-level security by organization membership. All mutations use role-checked, security-definer RPCs with server-side transition validation. Public/anonymous table and RPC access is revoked.
- A pricing/admin member creates changes and price lines. Prices and location scope lock at submission. Open work prevents sign-off. An admin/finance approver must be **different from the change owner**. Admin/operations can coordinate rollout and record a manual location confirmation. A change cannot be marked confirmed until every included location is manually confirmed.
- The portfolio and detail tabs read live records and show honest empty states. There are **no seeded organizations, sample pricing changes, example locations, or synthetic counts**.

## Important boundaries

- This is a **live coordination/approval backend**, not an automatic practice-management-system pricing connector. Adding a proposal does **not** modify clinic prices. A location confirmation records a human assertion that implementation was done and checked; it is not proof from a PMS. Current location scope is manually entered and is not tied to `std_clinics` records.
- Enterprise tables are intentionally separate from the legacy clinic pricing tables. **Live database audit (2026-09-22):** `anon` has table grants and permissive policies on `meta_clinic_users`, `std_service_prices`, `std_price_history`, `std_elasticity`, `std_price_experiments`, `std_clinic_baseline`, `price_approvals`, and `price_recommendations`; `anon` can also execute legacy RPCs including `approve_recommendation`, `implement_recommendation`, `engine_resume`, and `insight_revert_price`. The new enterprise tables themselves have forced RLS, no anon grants, and authenticated SELECT-only grants, with writes gated by RPCs. **Do not onboard sensitive enterprise customer data into this shared Supabase project until the legacy exposure is remediated or the enterprise workspace is moved to a separate project.** Do not change the legacy policies blindly: the existing clinic frontend may depend on them.
- Users may self-create an **isolated, empty** organization after login. Existing organization membership requires an admin to add an existing Vet INC account by email. This is not a vetted corporate onboarding or domain-ownership process. Review before inviting external enterprises.
- Existing site URL in Supabase Auth remains `http://localhost:3000`; only this exact GitHub Pages URL was added to `uri_allow_list` for email-link callbacks. Test actual email delivery separately with a real user, as no real inbox was used during automated verification.
- Email link may be subject to Supabase default mail limits because custom SMTP is not configured.

## Deployment and testing

- Migrations: `supabase/migrations/20260922_enterprise_workspace.sql` then `supabase/migrations/20260922_enterprise_price_items.sql`, deployed through the Supabase Management API. `-- DEPLOY-SPLIT` markers separate statements for the API. Do not blindly replay `CREATE POLICY` statements without checking whether they already exist.
- Automated checks: two ephemeral authenticated accounts exercised cross-organization isolation, role denial, scope locks, blocked approval with open work, sign-off, manual location confirmation, and persisted change status. A Playwright flow exercised the real UI against Supabase at desktop and phone widths. Test rows/users were removed afterwards; the cleanup requires deleting `enterprise_tasks` before memberships because of the assignee foreign key.
- To verify an empty production installation, query counts for `enterprise_orgs`, `enterprise_changes`, and `enterprise_price_items` via management API. Do not use the public anon key to inspect private records.
