//
//  MatchPointLiveActivityBundle.swift
//  MatchPointLiveActivity
//

import SwiftUI
import WidgetKit

@main
struct MatchPointLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        MatchPointScoreWidget()
        MatchPointFavoritePlayerWidget()
        MatchPointPlayerRankingWidget()
        MatchPointTodayBriefingWidget()
        MatchPointLiveActivityLiveActivity()
    }
}
