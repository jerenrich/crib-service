-- One bounded object on the existing journal row, not a write per span.
ALTER TABLE diagnostics ADD COLUMN details TEXT;
