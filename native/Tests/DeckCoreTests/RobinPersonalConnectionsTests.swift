import XCTest
@testable import DeckCore
final class RobinPersonalConnectionsTests:XCTestCase {
  func testAllPersonalReadsAreFixedGETEndpointsWithoutCredentialsInURLs() throws {
    for source in RobinPersonalSource.allCases {
      let request=try RobinPersonalRequest.request(source:source,query:"meeting & token=not-a-token",channels:["team"])
      XCTAssertEqual(request.httpMethod,"GET");XCTAssertEqual(request.url?.scheme,"https")
      XCTAssertNil(request.value(forHTTPHeaderField:"Authorization"));XCTAssertNil(request.url?.user)
      XCTAssertTrue(["gmail.googleapis.com","www.googleapis.com","tasks.googleapis.com","people.googleapis.com","slack.com"].contains(request.url!.host!))
    }
  }
  func testResourceTraversalAndUnapprovedSlackChannelsCannotBuildRequests() {
    for id in ["../secret","a/b",""] {XCTAssertThrowsError(try RobinPersonalRequest.request(source:.docs,query:"",resourceID:id))}
    XCTAssertThrowsError(try RobinPersonalRequest.request(source:.slack,query:"hello"))
    XCTAssertThrowsError(try RobinPersonalRequest.request(source:.slack,query:"hello",channels:["general OR in:private"]))
    XCTAssertThrowsError(try RobinPersonalRequest.request(source:.slack,query:"hello",channels:["a","b"]))
  }
  func testCalendarHasBoundedUpcomingWindowAndDocumentExportsAreReadOnly() throws {
    let request=try RobinPersonalRequest.request(source:.calendar,query:"",now:Date(timeIntervalSince1970:0))
    let query=URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!
    XCTAssertEqual(query.first{$0.name=="timeMin"}?.value,"1970-01-01T00:00:00Z")
    XCTAssertEqual(query.first{$0.name=="timeMax"}?.value,"1970-01-08T00:00:00Z")
    XCTAssertEqual(try RobinPersonalRequest.request(source:.docs,query:"",resourceID:"document-id").url?.path,"/drive/v3/files/document-id/export")
  }
  func testWritePreviewsUseFixedEndpointsAndRejectHeaderInjection() throws {
    let fields:[String:String] = ["to":"test@example.invalid","subject":"Review","body":"Synthetic draft","channel":"C123","text":"Synthetic","title":"Synthetic","start":"2026-11-03T10:00:00Z","end":"2026-11-03T11:00:00Z","documentID":"doc123","spreadsheetID":"sheet123","range":"Sheet1!A1:B2","values":"[[1,2]]","listID":"list123","taskID":"task123","contactID":"contact123","etag":"synthetic","sourceID":"source123","sourceEtag":"synthetic-source","givenName":"Synthetic"]
    for operation in RobinPersonalWrite.allCases {
      let draft=RobinPersonalDraft(accountID:"account",operation:operation,fields:fields)
      let request=try draft.request()
      XCTAssertTrue(["POST","PATCH","PUT"].contains(request.httpMethod!))
      XCTAssertTrue(["gmail.googleapis.com","www.googleapis.com","slack.com","docs.googleapis.com","sheets.googleapis.com","tasks.googleapis.com","people.googleapis.com"].contains(request.url!.host!))
      XCTAssertNil(request.value(forHTTPHeaderField:"Authorization"))
      XCTAssertTrue(draft.preview.contains("Synthetic"))
    }
    var invalid=fields;invalid["subject"]="Header\r\nBcc: someone@example.invalid"
    XCTAssertThrowsError(try RobinPersonalDraft(accountID:"account",operation:.gmailSend,fields:invalid).request())
    invalid=fields;invalid["end"]="2026-11-03T09:00:00Z"
    XCTAssertThrowsError(try RobinPersonalDraft(accountID:"account",operation:.calendarCreate,fields:invalid).request())
    invalid=fields;invalid["documentID"]="../../private"
    XCTAssertThrowsError(try RobinPersonalDraft(accountID:"account",operation:.documentAppend,fields:invalid).request())
  }
  func testAccountsDefaultToNoCloudSharing() throws {
    let account=RobinPersonalAccount(label:"Work",provider:"google",sources:[.calendar])
    XCTAssertTrue(account.destinations.isEmpty)
    XCTAssertEqual(try JSONDecoder().decode(RobinPersonalAccount.self,from:JSONEncoder().encode(account)),account)
  }
}
