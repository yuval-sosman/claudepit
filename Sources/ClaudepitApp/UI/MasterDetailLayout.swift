import SwiftUI

struct MasterDetailLayout<List: View, Detail: View>: View {
    let listWidth: CGFloat
    @ViewBuilder var list: () -> List
    @ViewBuilder var detail: () -> Detail
    var body: some View {
        HStack(spacing: 20) {
            list().frame(width: listWidth)
            detail().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
