-- Creates the user the integration tests connect as, in the pluggable database:
--   sqlplus -s system/<password>@//localhost:1521/FREEPDB1 @create_test_user.sql
-- SYSTEM's default tablespace is not ASSM, which JSON columns need, and the
-- lite Free image has no USERS tablespace, so the tests get their own, next
-- to the SYSAUX datafile.
WHENEVER SQLERROR EXIT FAILURE
DECLARE
  dir VARCHAR2(512);
BEGIN
  SELECT SUBSTR(file_name, 1, INSTR(file_name, '/', -1)) INTO dir
    FROM dba_data_files WHERE tablespace_name = 'SYSAUX' AND ROWNUM = 1;
  EXECUTE IMMEDIATE 'CREATE TABLESPACE orax_test DATAFILE ''' || dir ||
    'orax_test01.dbf'' SIZE 50M AUTOEXTEND ON NEXT 50M';
END;
/
CREATE USER orax_test IDENTIFIED BY "OraxTest1"
  DEFAULT TABLESPACE orax_test QUOTA UNLIMITED ON orax_test;
GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE, CREATE VIEW,
  CREATE PROCEDURE, CREATE TRIGGER TO orax_test;
EXIT
