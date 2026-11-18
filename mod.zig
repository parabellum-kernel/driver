const parabellum = @import("parabellum");
pub const memory = @import("parabellum_datasource_memory");
pub const file_store = @import("parabellum_datasource_file_store");
pub const sqlite = @import("parabellum_datasource_sqlite");
pub const yaml = @import("parabellum_datasource_yaml");
pub const yaml_file = yaml;
pub const ssh_store = @import("parabellum_datasource_ssh_store");
pub const gdrive_store = @import("parabellum_datasource_gdrive_store");

pub const MemoryRepository = memory.MemoryRepository;
pub const FileStoreRepository = file_store.FileStoreRepository;
pub const SqliteRepository = sqlite.SqliteRepository;
pub const YamlFileRepository = yaml.YamlFileRepository;
pub const SshStoreRepository = ssh_store.SshStoreRepository;
pub const GDriveStoreRepository = gdrive_store.GDriveStoreRepository;

pub fn registerDefaultDrivers(registry: *parabellum.repository.RepositoryRegistry) !void {
    try registry.registerDriver("memory", &memory.MemoryRepository.createHeap);
    try registry.registerDriver("file_store", &file_store.FileStoreRepository.createHeap);
    try registry.registerDriver("sqlite", &sqlite.SqliteRepository.createHeap);
    try registry.registerDriver("yaml", &yaml.YamlFileRepository.createHeap);
    try registry.registerDriver("yaml_file", &yaml.YamlFileRepository.createHeap);
    try registry.registerDriver("ssh_store", &ssh_store.SshStoreRepository.createHeap);
    try registry.registerDriver("gdrive_store", &gdrive_store.GDriveStoreRepository.createHeap);
}

// Per-driver kernel extensions (opt-in individually without bundling all backends)
pub const memory_extension = parabellum.kernel.Extension.fromStateless("parabellum.driver.memory", struct {
    fn reg(k: *parabellum.kernel.KernelContext) anyerror!void {
        try k.datasources.registerDriver("memory", &memory.MemoryRepository.createHeap);
    }
}.reg);

pub const sqlite_extension = parabellum.kernel.Extension.fromStateless("parabellum.driver.sqlite", struct {
    fn reg(k: *parabellum.kernel.KernelContext) anyerror!void {
        try k.datasources.registerDriver("sqlite", &sqlite.SqliteRepository.createHeap);
    }
}.reg);

pub const extension = parabellum.kernel.Extension.fromStateless(
    "parabellum.datasources.default",
    &registerExtension,
);

pub fn registerExtension(kernel: *parabellum.kernel.KernelContext) anyerror!void {
    try registerDefaultDrivers(&kernel.datasources);
}
