ALTER TABLE cloud_libraries ADD COLUMN metadata_bytes bigint NOT NULL DEFAULT 0;
ALTER TABLE cloud_media ADD COLUMN unreferenced_since timestamptz;
CREATE FUNCTION cloud_count_metadata() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE delta bigint := 0; owner uuid;
BEGIN
  IF TG_OP != 'DELETE' THEN delta := octet_length(to_jsonb(NEW)::text); owner := NEW.account_id; END IF;
  IF TG_OP != 'INSERT' THEN delta := delta-octet_length(to_jsonb(OLD)::text); owner := OLD.account_id; END IF;
  UPDATE cloud_libraries SET metadata_bytes=GREATEST(0,metadata_bytes+delta) WHERE account_id=owner;
  RETURN NULL;
END;
$$;
CREATE TRIGGER cloud_record_bytes AFTER INSERT OR UPDATE OR DELETE ON cloud_records FOR EACH ROW EXECUTE FUNCTION cloud_count_metadata();
CREATE TRIGGER cloud_change_bytes AFTER INSERT OR UPDATE OR DELETE ON cloud_changes FOR EACH ROW EXECUTE FUNCTION cloud_count_metadata();
CREATE TRIGGER cloud_operation_bytes AFTER INSERT OR UPDATE OR DELETE ON cloud_operations FOR EACH ROW EXECUTE FUNCTION cloud_count_metadata();
UPDATE cloud_libraries l SET metadata_bytes=
  COALESCE((SELECT sum(octet_length(to_jsonb(r)::text)) FROM cloud_records r WHERE r.account_id=l.account_id),0)+
  COALESCE((SELECT sum(octet_length(to_jsonb(c)::text)) FROM cloud_changes c WHERE c.account_id=l.account_id),0)+
  COALESCE((SELECT sum(octet_length(to_jsonb(o)::text)) FROM cloud_operations o WHERE o.account_id=l.account_id),0);
CREATE TABLE cloud_object_cleanup (
  account_id uuid NOT NULL REFERENCES accounts(id), epoch uuid NOT NULL,
  PRIMARY KEY(account_id,epoch)
);
CREATE TABLE cloud_media_cleanup (
  account_id uuid NOT NULL REFERENCES cloud_libraries(account_id) ON DELETE CASCADE,
  epoch uuid NOT NULL, id uuid NOT NULL, PRIMARY KEY(account_id,epoch,id)
);
