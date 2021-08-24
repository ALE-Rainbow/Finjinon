//
//  OTC.swift
// 

extension String {
    var deletingPathExtension : String {
        get {
            return (self as NSString).deletingPathExtension
        }
    }
}

class OTC {
    private static func sourceFileName(filePath: String) -> String {
        let components = filePath.components(separatedBy: "/")
        return components.isEmpty ? "" : components.last!.deletingPathExtension
    }
    
    static func log( _ format: String,
                     _ args: CVarArg...,
                     filename: String = #file,
                     line: Int = #line,
                     funcName: String = #function) {
        let logFormat = "[\(sourceFileName(filePath: filename)):\(line)] \(funcName) - \(String(format: format, arguments: args))"
        NSLogv(logFormat, getVaList(args))
    }
}
