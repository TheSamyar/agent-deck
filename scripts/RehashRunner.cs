using System;
using System.Reflection;

class P {
  static void Main(string[] args) {
    if (args.Length < 1 || string.IsNullOrWhiteSpace(args[0])) {
      Console.Error.WriteLine("usage: RehashRunner <dist-dir>");
      Environment.Exit(1);
    }
    var asm = Assembly.LoadFrom("/Applications/Utilities/LogiPluginService.app/Contents/MonoBundle/LoupedeckShared.dll");
    var type = asm.GetType("Loupedeck.Service.LibraryPackageHashFile");
    var method = type.GetMethod("CreateHashFile", BindingFlags.Public | BindingFlags.Static, null, new[] { typeof(string) }, null);
    method.Invoke(null, new object[] { args[0] });
  }
}
