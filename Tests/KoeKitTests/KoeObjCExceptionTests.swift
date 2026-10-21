import Foundation
import KoeObjC
import Testing

struct KoeObjCExceptionTests {
    @Test func NSExceptionはSwiftのエラーに変換される() {
        let array = NSArray()
        #expect(throws: (any Error).self) {
            try KoeObjCException.catching { _ = array.object(at: 3) }
        }
        do {
            try KoeObjCException.catching { _ = array.object(at: 3) }
        } catch let error as NSError {
            #expect(error.domain == KoeObjCExceptionErrorDomain)
            #expect(error.userInfo[KoeObjCExceptionNameKey] as? String == NSExceptionName.rangeException.rawValue)
        }
    }

    @Test func 例外がなければそのまま通る() throws {
        var ran = false
        try KoeObjCException.catching { ran = true }
        #expect(ran)
    }
}
