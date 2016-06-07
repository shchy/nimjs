#
#
#            Nim's Runtime Library
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## A higher level `mySQL`:idx: database wrapper. The same interface is
## implemented for other databases too.
##
## See also: `db_odbc <db_odbc.html>`_, `db_sqlite <db_sqlite.html>`_,
## `db_postgres <db_postgres.html>`_.
##
## Parameter substitution
## ----------------------
##
## All ``db_*`` modules support the same form of parameter substitution.
## That is, using the ``?`` (question mark) to signify the place where a
## value should be placed. For example:
##
## .. code-block:: Nim
##     sql"INSERT INTO myTable (colA, colB, colC) VALUES (?, ?, ?)"
##
##
## Examples
## --------
##
## Opening a connection to a database
## ==================================
##
## .. code-block:: Nim
##     import db_mysql
##     let db = open("localhost", "user", "password", "dbname")
##     db.close()
##
## Creating a table
## ================
##
## .. code-block:: Nim
##      db.exec(sql"DROP TABLE IF EXISTS myTable")
##      db.exec(sql("""CREATE TABLE myTable (
##                       id integer,
##                       name varchar(50) not null)"""))
##
## Inserting data
## ==============
##
## .. code-block:: Nim
##     db.exec(sql"INSERT INTO myTable (id, name) VALUES (0, ?)",
##             "Dominik")
##
## Larger example
## ==============
##
## .. code-block:: Nim
##
##  import db_mysql, math
##
##  let theDb = open("localhost", "nim", "nim", "test")
##
##  theDb.exec(sql"Drop table if exists myTestTbl")
##  theDb.exec(sql("create table myTestTbl (" &
##      " Id    INT(11)     NOT NULL AUTO_INCREMENT PRIMARY KEY, " &
##      " Name  VARCHAR(50) NOT NULL, " &
##      " i     INT(11), " &
##      " f     DECIMAL(18,10))"))
##
##  theDb.exec(sql"START TRANSACTION")
##  for i in 1..1000:
##    theDb.exec(sql"INSERT INTO myTestTbl (name,i,f) VALUES (?,?,?)",
##          "Item#" & $i, i, sqrt(i.float))
##  theDb.exec(sql"COMMIT")
##
##  for x in theDb.fastRows(sql"select * from myTestTbl"):
##    echo x
##
##  let id = theDb.tryInsertId(sql"INSERT INTO myTestTbl (name,i,f) VALUES (?,?,?)",
##          "Item#1001", 1001, sqrt(1001.0))
##  echo "Inserted item: ", theDb.getValue(sql"SELECT name FROM myTestTbl WHERE id=?", id)
##
##  theDb.close()


import strutils, mysql

import db_common
export db_common

type
  DbConn* = PMySQL     ## encapsulates a database connection
  Row* = seq[string]   ## a row of a dataset. NULL database values will be
                       ## converted to nil.
  InstantRow* = object ## a handle that can be used to get a row's
                       ## column text on demand
    row: cstringArray
    len: int
{.deprecated: [TRow: Row, TDbConn: DbConn].}

proc dbError*(db: DbConn) {.noreturn.} =
  ## raises a DbError exception.
  var e: ref DbError
  new(e)
  e.msg = $mysql.error(db)
  raise e

when false:
  proc dbQueryOpt*(db: DbConn, query: string, args: varargs[string, `$`]) =
    var stmt = mysql_stmt_init(db)
    if stmt == nil: dbError(db)
    if mysql_stmt_prepare(stmt, query, len(query)) != 0:
      dbError(db)
    var
      binding: seq[MYSQL_BIND]
    discard mysql_stmt_close(stmt)

proc dbQuote*(s: string): string =
  ## DB quotes the string.
  result = "'"
  for c in items(s):
    if c == '\'': add(result, "''")
    else: add(result, c)
  add(result, '\'')

proc dbFormat(formatstr: SqlQuery, args: varargs[string]): string =
  result = ""
  var a = 0
  for c in items(string(formatstr)):
    if c == '?':
      if args[a] == nil:
        add(result, "NULL")
      else:
        add(result, dbQuote(args[a]))
      inc(a)
    else:
      add(result, c)

proc tryExec*(db: DbConn, query: SqlQuery, args: varargs[string, `$`]): bool {.
  tags: [ReadDbEffect, WriteDbEffect].} =
  ## tries to execute the query and returns true if successful, false otherwise.
  var q = dbFormat(query, args)
  return mysql.realQuery(db, q, q.len) == 0'i32

proc rawExec(db: DbConn, query: SqlQuery, args: varargs[string, `$`]) =
  var q = dbFormat(query, args)
  if mysql.realQuery(db, q, q.len) != 0'i32: dbError(db)

proc exec*(db: DbConn, query: SqlQuery, args: varargs[string, `$`]) {.
  tags: [ReadDbEffect, WriteDbEffect].} =
  ## executes the query and raises EDB if not successful.
  var q = dbFormat(query, args)
  if mysql.realQuery(db, q, q.len) != 0'i32: dbError(db)

proc newRow(L: int): Row =
  newSeq(result, L)
  for i in 0..L-1: result[i] = ""

proc properFreeResult(sqlres: mysql.PRES, row: cstringArray) =
  if row != nil:
    while mysql.fetchRow(sqlres) != nil: discard
  mysql.freeResult(sqlres)

iterator fastRows*(db: DbConn, query: SqlQuery,
                   args: varargs[string, `$`]): Row {.tags: [ReadDbEffect].} =
  ## executes the query and iterates over the result dataset.
  ##
  ## This is very fast, but potentially dangerous.  Use this iterator only
  ## if you require **ALL** the rows.
  ##
  ## Breaking the fastRows() iterator during a loop will cause the next
  ## database query to raise an [EDb] exception ``Commands out of sync``.
  rawExec(db, query, args)
  var sqlres = mysql.useResult(db)
  if sqlres != nil:
    var L = int(mysql.numFields(sqlres))
    var result = newRow(L)
    var row: cstringArray
    while true:
      row = mysql.fetchRow(sqlres)
      if row == nil: break
      for i in 0..L-1:
        setLen(result[i], 0)
        if row[i] == nil:
          result[i] = nil
        else:
          add(result[i], row[i])
      yield result
    properFreeResult(sqlres, row)

iterator instantRows*(db: DbConn, query: SqlQuery,
                      args: varargs[string, `$`]): InstantRow
                      {.tags: [ReadDbEffect].} =
  ## Same as fastRows but returns a handle that can be used to get column text
  ## on demand using []. Returned handle is valid only within the iterator body.
  rawExec(db, query, args)
  var sqlres = mysql.useResult(db)
  if sqlres != nil:
    let L = int(mysql.numFields(sqlres))
    var row: cstringArray
    while true:
      row = mysql.fetchRow(sqlres)
      if row == nil: break
      yield InstantRow(row: row, len: L)
    properFreeResult(sqlres, row)

proc setTypeName(t: var DbType; f: PFIELD) =
  shallowCopy(t.name, $f.name)
  t.maxReprLen = Natural(f.max_length)
  if (NOT_NULL_FLAG and f.flags) != 0: t.notNull = true
  case f.ftype
  of TYPE_DECIMAL:
    t.kind = dbDecimal
  of TYPE_TINY:
    t.kind = dbInt
    t.size = 1
  of TYPE_SHORT:
    t.kind = dbInt
    t.size = 2
  of TYPE_LONG:
    t.kind = dbInt
    t.size = 4
  of TYPE_FLOAT:
    t.kind = dbFloat
    t.size = 4
  of TYPE_DOUBLE:
    t.kind = dbFloat
    t.size = 8
  of TYPE_NULL:
    t.kind = dbNull
  of TYPE_TIMESTAMP:
    t.kind = dbTimestamp
  of TYPE_LONGLONG:
    t.kind = dbInt
    t.size = 8
  of TYPE_INT24:
    t.kind = dbInt
    t.size = 3
  of TYPE_DATE:
    t.kind = dbDate
  of TYPE_TIME:
    t.kind = dbTime
  of TYPE_DATETIME:
    t.kind = dbDatetime
  of TYPE_YEAR:
    t.kind = dbDate
  of TYPE_NEWDATE:
    t.kind = dbDate
  of TYPE_VARCHAR, TYPE_VAR_STRING, TYPE_STRING:
    t.kind = dbVarchar
  of TYPE_BIT:
    t.kind = dbBit
  of TYPE_NEWDECIMAL:
    t.kind = dbDecimal
  of TYPE_ENUM: t.kind = dbEnum
  of TYPE_SET: t.kind = dbSet
  of TYPE_TINY_BLOB, TYPE_MEDIUM_BLOB, TYPE_LONG_BLOB,
     TYPE_BLOB: t.kind = dbBlob
  of TYPE_GEOMETRY:
    t.kind = dbGeometry

proc setColumnInfo(columns: var DbColumns; res: PRES; L: int) =
  setLen(columns, L)
  for i in 0..<L:
    let fp = mysql.fetch_field_direct(res, cint(i))
    setTypeName(columns[i].typ, fp)
    columns[i].name = $fp.name
    columns[i].tableName = $fp.table
    columns[i].primaryKey = (fp.flags and PRI_KEY_FLAG) != 0
    #columns[i].foreignKey = there is no such thing in mysql

iterator instantRows*(db: DbConn; columns: var DbColumns; query: SqlQuery;
                      args: varargs[string, `$`]): InstantRow =
  ## Same as fastRows but returns a handle that can be used to get column text
  ## on demand using []. Returned handle is valid only within the iterator body.
  rawExec(db, query, args)
  var sqlres = mysql.useResult(db)
  if sqlres != nil:
    let L = int(mysql.numFields(sqlres))
    setColumnInfo(columns, sqlres, L)
    var row: cstringArray
    while true:
      row = mysql.fetchRow(sqlres)
      if row == nil: break
      yield InstantRow(row: row, len: L)
    properFreeResult(sqlres, row)


proc `[]`*(row: InstantRow, col: int): string {.inline.} =
  ## Returns text for given column of the row.
  $row.row[col]

proc len*(row: InstantRow): int {.inline.} =
  ## Returns number of columns in the row.
  row.len

proc getRow*(db: DbConn, query: SqlQuery,
             args: varargs[string, `$`]): Row {.tags: [ReadDbEffect].} =
  ## Retrieves a single row. If the query doesn't return any rows, this proc
  ## will return a Row with empty strings for each column.
  rawExec(db, query, args)
  var sqlres = mysql.useResult(db)
  if sqlres != nil:
    var L = int(mysql.numFields(sqlres))
    result = newRow(L)
    var row = mysql.fetchRow(sqlres)
    if row != nil:
      for i in 0..L-1:
        setLen(result[i], 0)
        if row[i] == nil:
          result[i] = nil
        else:
          add(result[i], row[i])
    properFreeResult(sqlres, row)

proc getAllRows*(db: DbConn, query: SqlQuery,
                 args: varargs[string, `$`]): seq[Row] {.tags: [ReadDbEffect].} =
  ## executes the query and returns the whole result dataset.
  result = @[]
  rawExec(db, query, args)
  var sqlres = mysql.useResult(db)
  if sqlres != nil:
    var L = int(mysql.numFields(sqlres))
    var row: cstringArray
    var j = 0
    while true:
      row = mysql.fetchRow(sqlres)
      if row == nil: break
      setLen(result, j+1)
      newSeq(result[j], L)
      for i in 0..L-1:
        if row[i] == nil:
          result[j][i] = nil
        else:
          result[j][i] = $row[i]
      inc(j)
    mysql.freeResult(sqlres)

iterator rows*(db: DbConn, query: SqlQuery,
               args: varargs[string, `$`]): Row {.tags: [ReadDbEffect].} =
  ## same as `fastRows`, but slower and safe.
  for r in items(getAllRows(db, query, args)): yield r

proc getValue*(db: DbConn, query: SqlQuery,
               args: varargs[string, `$`]): string {.tags: [ReadDbEffect].} =
  ## executes the query and returns the first column of the first row of the
  ## result dataset. Returns "" if the dataset contains no rows or the database
  ## value is NULL.
  result = getRow(db, query, args)[0]

proc tryInsertId*(db: DbConn, query: SqlQuery,
                  args: varargs[string, `$`]): int64 {.tags: [WriteDbEffect].} =
  ## executes the query (typically "INSERT") and returns the
  ## generated ID for the row or -1 in case of an error.
  var q = dbFormat(query, args)
  if mysql.realQuery(db, q, q.len) != 0'i32:
    result = -1'i64
  else:
    result = mysql.insertId(db)

proc insertId*(db: DbConn, query: SqlQuery,
               args: varargs[string, `$`]): int64 {.tags: [WriteDbEffect].} =
  ## executes the query (typically "INSERT") and returns the
  ## generated ID for the row.
  result = tryInsertID(db, query, args)
  if result < 0: dbError(db)

proc execAffectedRows*(db: DbConn, query: SqlQuery,
                       args: varargs[string, `$`]): int64 {.
                       tags: [ReadDbEffect, WriteDbEffect].} =
  ## runs the query (typically "UPDATE") and returns the
  ## number of affected rows
  rawExec(db, query, args)
  result = mysql.affectedRows(db)

proc close*(db: DbConn) {.tags: [DbEffect].} =
  ## closes the database connection.
  if db != nil: mysql.close(db)

proc open*(connection, user, password, database: string): DbConn {.
  tags: [DbEffect].} =
  ## opens a database connection. Raises `EDb` if the connection could not
  ## be established.
  result = mysql.init(nil)
  if result == nil: dbError("could not open database connection")
  let
    colonPos = connection.find(':')
    host = if colonPos < 0: connection
           else: substr(connection, 0, colonPos-1)
    port: int32 = if colonPos < 0: 0'i32
                  else: substr(connection, colonPos+1).parseInt.int32
  if mysql.realConnect(result, host, user, password, database,
                       port, nil, 0) == nil:
    var errmsg = $mysql.error(result)
    db_mysql.close(result)
    dbError(errmsg)

proc setEncoding*(connection: DbConn, encoding: string): bool {.
  tags: [DbEffect].} =
  ## sets the encoding of a database connection, returns true for
  ## success, false for failure.
  result = mysql.set_character_set(connection, encoding) == 0