import RielaCLI

@main
struct RielaAddonWorkerMain {
  static func main() async {
    await BuiltinAddonWorker.run()
  }
}
