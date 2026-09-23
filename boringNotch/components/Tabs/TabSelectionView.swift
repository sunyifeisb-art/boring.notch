//
//  TabSelectionView.swift
//  boringNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import Defaults
import SwiftUI

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

let homeTab = TabModel(label: "主页", icon: "house.fill", view: .home)
let agentsTab = TabModel(label: "Agent", icon: "terminal.fill", view: .agents)

let shelfTab = TabModel(label: "文件", icon: "tray.fill", view: .shelf)

struct TabSelectionView: View {
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @Default(.boringShelf) private var boringShelf
    @AppStorage("agentIslandEnabled") private var agentIslandEnabled = true
    @Namespace var animation

    private var tabs: [TabModel] {
        var items = [homeTab]
        // Agent 任务入口优先，文件存储器作为第二入口，保持用户处理任务时的路径最短。
        if agentIslandEnabled { items.append(agentsTab) }
        if boringShelf { items.append(shelfTab) }
        return items
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview {
    BoringHeader().environmentObject(BoringViewModel())
}
