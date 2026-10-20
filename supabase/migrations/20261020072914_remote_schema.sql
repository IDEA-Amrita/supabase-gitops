DROP INDEX "public"."idx_members_dept_active";

DROP INDEX "public"."idx_projects_status";

ALTER TABLE "public"."members"
  ADD COLUMN "roll_no" text NOT NULL;

ALTER TABLE "public"."members"
  ADD COLUMN "ph_no" text;

ALTER TABLE "public"."members"
  ADD CONSTRAINT "members_ph_no_format" CHECK ((ph_no ~ '^[0-9]{10}$'::text));

ALTER TABLE "public"."members"
  ADD CONSTRAINT "members_roll_no_format" CHECK (((roll_no = lower(TRIM(BOTH FROM roll_no))) AND (length(roll_no) > 0)));

ALTER TABLE "public"."members"
  ADD CONSTRAINT "uq_members_roll_no" UNIQUE (roll_no);

