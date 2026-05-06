//
//  ContentView.swift
//  BitbucketBuildMonitor
//
//  Created by Jan Tore Bøe on 13/04/2025.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack {
            Image(systemName: "checkmark.circle.fill")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Bitbucket Build Monitor")
        }
        .padding()
    }
}
