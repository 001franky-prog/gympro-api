\set ON_ERROR_STOP on
BEGIN;
SELECT pg_catalog.set_config('gympro.rehearsal_target', :'target', true);
DO $guard$ BEGIN
 IF current_database()<>current_setting('gympro.rehearsal_target') OR current_database() !~ '^gympro_bootstrap_[0-9]{14}_[a-f0-9]{6}$' OR current_user<>'postgres' THEN RAISE EXCEPTION 'Unsafe bootstrap target'; END IF;
END $guard$;
INSERT INTO app.permissions (id,module_code,resource_code,action_code,description,is_active) VALUES
('274560ef-1293-4cca-ab8b-6569a774e34d'::uuid,'cms','announcements','create','Create announcements',true),
('d95e59b6-3ab3-49d8-8390-539f3c2bf2e0'::uuid,'cms','announcements','publish','Publish announcements',true),
('00f9cde3-4f7c-4d8b-91ac-de5ef634c276'::uuid,'cms','announcements','read','View announcements',true),
('64292934-c533-4d4f-8ddd-6ead86498af0'::uuid,'finance','payments','read','Read authorized payment records',true),
('f326b97d-68db-4a64-9da9-b3aac2a019e6'::uuid,'finance','payments','record','Record an authorized payment receipt',true),
('ab9b6c70-f296-4b3b-97f4-d42dfcdad717'::uuid,'finance','payments','reverse','Record authorized payment reversals',true),
('88f60330-7f1f-4479-96eb-68bbc22d5321'::uuid,'finance','reconciliation','manage','Manage payment reconciliation',true),
('befb9b40-53bf-49a7-bf15-9fce158a939d'::uuid,'gym','attendance','manage','Manage attendance records',true),
('0de3eb1f-19dd-496d-a320-423b3c1e79e8'::uuid,'gym','attendance','read','View attendance',true),
('c4be04a8-ded1-4c5f-8b55-dc6fb7d7a6a0'::uuid,'gym','attendance','record','Record attendance',true),
('555f851d-1e5b-492d-b96c-fe251e7ac110'::uuid,'gym','cards','manage','Issue and revoke member cards',true),
('2523f93c-30b9-46a3-ba02-f00ce64af467'::uuid,'gym','cards','read','Read member card details',true),
('dd1229ef-dd20-49bd-9e2f-977828e6a7fd'::uuid,'gym','members','create','Register gym members',true),
('1e73368b-7c1b-4afd-8f34-e1b04c0ea3c6'::uuid,'gym','members','delete','Delete gym members',true),
('2c38c6f0-25c8-4761-9948-8cd386b1d8c2'::uuid,'gym','members','read','View gym members',true),
('46f8ee7b-a194-4b10-9eac-84be4c109ed2'::uuid,'gym','members','update','Update gym members',true),
('4e2097e9-4612-47ad-9ea1-e09fe750dce3'::uuid,'gym','memberships','apply_discount','Apply an eligible promotion to a membership purchase',true),
('fca95913-3644-407b-8207-b2c6cdbbfb59'::uuid,'gym','memberships','grant_foc','Grant complimentary membership with a required reason and audit history.',true),
('39c243b9-a010-4479-9c1b-bc110dabbc85'::uuid,'gym','memberships','manage','Manage memberships',true),
('38aa493c-9669-4d9b-8399-9fc3f6ce73bc'::uuid,'gym','promotions','manage','Create and manage tenant membership promotions',true),
('69899d09-d941-437e-9778-0530f845f749'::uuid,'inventory','products','create','Create products',true),
('2bb385d8-54bd-4554-a1ab-6a380f46c706'::uuid,'inventory','products','read','View products',true),
('cfb6446c-610d-4992-b236-29627a7324d5'::uuid,'inventory','products','update','Update products',true),
('16268e4f-ba1a-4bd8-b52e-8b115a4562ad'::uuid,'inventory','stock','adjust','Adjust stock',true),
('92e15271-9a35-4bdf-ba76-441383fb9a66'::uuid,'pos','sales','create','Create POS sales',true),
('77dd3886-c216-4a4d-8a5b-3ff795a4a85a'::uuid,'pos','sales','read','View sales',true),
('4d573777-bfc6-4441-b408-4ca30eb861b9'::uuid,'pos','sales','refund','Process refunds',true),
('f28b9798-f727-4bf8-953b-f95349278a94'::uuid,'pos','sales','void','Void sales',true),
('9e5abee1-a23e-444e-bf83-ab9543dccb2c'::uuid,'reports','attendance','read','View attendance reports',true),
('f6034c2f-8048-48e4-bb68-cfa0994a23e9'::uuid,'reports','membership','read','View membership reports',true),
('7f7e5f72-4d33-42a9-ac91-4ffe85f92d10'::uuid,'reports','revenue','read','View revenue reports',true),
('0e3a0357-8af6-46d4-b16a-8bb6bbbfb8a8'::uuid,'tenant','branches','manage','Manage branches',true),
('20195f2e-1b4b-4217-ac9a-f877e13c2e7c'::uuid,'tenant','branches','read','View tenant branches',true),
('2c072a2a-42b2-4200-8ed1-3cd9bff84cb2'::uuid,'tenant','roles','manage','Manage roles and grants',true),
('3408468c-74f2-40f3-acf1-b402566befa1'::uuid,'tenant','roles','read','View tenant roles',true),
('78d4a546-5d51-486f-ac25-0840cbefd3ca'::uuid,'tenant','users','create','Create tenant users',true),
('00f36ba5-7447-4a7c-ac8d-d8567ec766b9'::uuid,'tenant','users','disable','Disable tenant users',true),
('b935dc0a-d13d-4c3c-b0b9-2034dfad2b61'::uuid,'tenant','users','read','View tenant users',true),
('78d6bbe8-6fb0-4e1f-85d3-0f84a9dc4394'::uuid,'tenant','users','update','Update tenant users',true)
ON CONFLICT (permission_code) DO NOTHING;
COMMIT;
