//
//  logger.swift
//  MyMacApp
//
//  Created by Yunhao on 2019/5/26.
//  Copyright © 2019 Yunhao. All rights reserved.
//

import Foundation

func DLog<T> (_ message : T, fileName : String = #file, method : String = #function, line : Int = #line)->(){
    #if DEBUG
    NSLog("[DEBUG]\(NSString(string: fileName).lastPathComponent):\(method):\(line): \(message)")
//    print()
    #endif
}
