#include <sqlite3.h>
#include <stddef.h>

/* Swift cannot call SQLite's variadic sqlite3_db_config declaration directly. */
static inline int nativeAgentSQLiteSetCheckpointOnClose(sqlite3 *database, int enabled) {
    return sqlite3_db_config(
        database,
        SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE,
        enabled ? 0 : 1,
        NULL
    );
}

static inline int nativeAgentSQLiteSetPersistentWAL(sqlite3 *database, int persistent) {
    int setting = persistent;
    return sqlite3_file_control(
        database,
        "main",
        SQLITE_FCNTL_PERSIST_WAL,
        &setting
    );
}
