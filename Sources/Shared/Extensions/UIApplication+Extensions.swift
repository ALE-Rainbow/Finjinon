//
//  UIApplication+Extensions.swift
//

import Foundation

extension UIApplication {
    static var mainScene : UIWindowScene? {
        guard let scene = UIApplication.shared.connectedScenes.first(where: { $0.session.role == .windowApplication }) as? UIWindowScene else {
            return nil
        }
        
        return scene
    }
 
    static var keyWindow : UIWindow? {
        return mainScene?.keyWindow
    }
}
