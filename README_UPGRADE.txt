SKILLLINK PRODUCTION UPGRADE

1. Replace the current GitHub index.html with this package's index.html.
2. In Supabase SQL Editor, run skilllink_upgrade.sql AFTER your existing skilllink_final_production.sql.
3. The upgrade adds:
   - CEO-only Command Center with user role/status management
   - CEO withdrawal control: Approved / Rejected / Paid
   - Company QR upload and company UPI/general settings
   - Lead creation and assignment to Partner/Admin
   - CEO/Admin notification sending to Everyone / Partners / Admins / Clients
   - Partner-only personal Levels & Rewards
   - Company QR display on Partner/Admin withdrawal page
4. Never put Supabase service_role/secret keys in index.html or GitHub.
5. After replacing index.html and running SQL, commit to GitHub. Vercel will redeploy automatically.
