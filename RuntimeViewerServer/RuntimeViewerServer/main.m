extern void swift_initializeRuntimeViewerServer(void);

__attribute__((constructor, used))
static void initializeRuntimeViewerServer(void) {
    swift_initializeRuntimeViewerServer();
}
