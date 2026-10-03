#define _GNU_SOURCE
#include <dlfcn.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#ifdef __APPLE__
#define WRAPPER(name) crash_##name
#else
#define WRAPPER(name) name
#endif
static void stop_after(const char *operation, const char *path, int result) {
    const char *op=getenv("ASK_CRASH_OP"), *suffix=getenv("ASK_CRASH_SUFFIX");
    if (result != 0 || !op || !suffix || strcmp(op, operation)) return;
    size_t n=strlen(path), k=strlen(suffix);
    if (n>=k && strcmp(path+n-k, suffix)==0) {
        dprintf(2, "injected crash after %s %s\n", operation, path);
        _exit(90);
    }
}
int WRAPPER(rename)(const char *old, const char *new) {
#ifdef __APPLE__
    int (*real)(const char*,const char*)=rename;
#else
    int (*real)(const char*,const char*)=dlsym(RTLD_NEXT,"rename");
#endif
    int result=real(old,new);stop_after("rename",new,result);return result;
}
int WRAPPER(renameat)(int od, const char *old, int nd, const char *new) {
#ifdef __APPLE__
    int (*real)(int,const char*,int,const char*)=renameat;
#else
    int (*real)(int,const char*,int,const char*)=dlsym(RTLD_NEXT,"renameat");
#endif
    int result=real(od,old,nd,new);stop_after("rename",new,result);return result;
}
int WRAPPER(unlink)(const char *path) {
#ifdef __APPLE__
    int (*real)(const char*)=unlink;
#else
    int (*real)(const char*)=dlsym(RTLD_NEXT,"unlink");
#endif
    int result=real(path);stop_after("unlink",path,result);return result;
}
int WRAPPER(unlinkat)(int dir, const char *path, int flags) {
#ifdef __APPLE__
    int (*real)(int,const char*,int)=unlinkat;
#else
    int (*real)(int,const char*,int)=dlsym(RTLD_NEXT,"unlinkat");
#endif
    int result=real(dir,path,flags);stop_after("unlink",path,result);return result;
}
#ifdef __APPLE__
__attribute__((used)) static const struct { const void *replacement; const void *original; }
interpositions[] __attribute__((section("__DATA,__interpose"))) = {
    { (const void *)crash_rename, (const void *)rename },
    { (const void *)crash_renameat, (const void *)renameat },
    { (const void *)crash_unlink, (const void *)unlink },
    { (const void *)crash_unlinkat, (const void *)unlinkat },
};
#endif
