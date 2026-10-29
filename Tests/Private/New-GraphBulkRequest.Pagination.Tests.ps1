BeforeAll {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

    function Get-CippTable { param($TableName) }
    function Get-CIPPAzDataTableEntity { param($Filter) }
    function Update-AzDataTableEntity { param($Entity, [switch]$Force) }
    function Invoke-CIPPRestMethod { param($Uri, $Method, $Headers, $ContentType, $Body) }
    function Get-GraphToken { param($TenantId, $Scope, $AsApp) }

    . (Join-Path $RepoRoot 'Modules/CIPPCore/Public/GraphHelper/New-GraphBulkRequest.ps1')
}

Describe 'New-GraphBulkRequest pagination' {
    BeforeEach {
        $script:Tenant = [pscustomobject]@{ GraphErrorCount = 3; LastGraphError = 'previous failure' }
        $script:Parameters = @{
            TenantId      = 'fixture.invalid'
            NoAuthCheck   = $true
            Headers       = @{ Authorization = 'synthetic' }
            Requests      = @(@{ id = 'members'; method = 'GET'; url = '/groups/fixture/members' })
        }
        $script:Replies = [System.Collections.Generic.Queue[string]]::new()
        $script:Replies.Enqueue(@'
{"responses":[{"id":"members","status":200,"body":{"value":[{"id":"first"}],"@odata.nextLink":"https://graph.microsoft.com/beta/groups/fixture/members?page=2"}}]}
'@)
        $script:SentRequests = [System.Collections.Generic.List[object]]::new()
        Mock Get-CippTable { @{} }
        Mock Get-CIPPAzDataTableEntity { $script:Tenant }
        Mock Update-AzDataTableEntity { }
        Mock Get-GraphToken { throw 'Unexpected token acquisition in offline pagination test' }
        Mock Invoke-CIPPRestMethod {
            $script:SentRequests.Add(($Body | ConvertFrom-Json))
            if ($script:Replies.Count -eq 0) { throw 'Unexpected REST request in offline pagination test' }
            $script:Replies.Dequeue() | ConvertFrom-Json
        }
    }

    It 'throws and records a continuation HTTP <Status> without emitting partial data' -ForEach @(
        @{ Status = 429; Code = 'TooManyRequests'; Detail = 'fixture throttle' }
        @{ Status = 403; Code = 'Authorization_RequestDenied'; Detail = 'fixture denied' }
        @{ Status = 503; Code = 'ServiceUnavailable'; Detail = 'fixture unavailable' }
    ) {
        $script:Replies.Enqueue((@{
                responses = @(@{ id = 'members'; status = $Status; body = @{ error = @{ code = $Code; message = $Detail } } })
            } | ConvertTo-Json -Compress -Depth 10))
        $Output = [System.Collections.Generic.List[object]]::new()

        { New-GraphBulkRequest @script:Parameters | ForEach-Object { $Output.Add($_) } } |
            Should -Throw "*pagination*members*$Status*$Code*$Detail*"

        $Output.Count | Should -Be 0
        $script:Tenant.GraphErrorCount | Should -Be 4
        $script:Tenant.LastGraphError | Should -BeLike "*members*$Status*$Detail*"
        Should -Invoke Update-AzDataTableEntity -Times 1 -Exactly
        Should -Invoke Invoke-CIPPRestMethod -Times 2 -Exactly
    }

    It 'rejects <Name> instead of returning a successful partial collection' -ForEach @(
        @{ Name = 'a missing batch envelope'; Reply = 'null' }
        @{ Name = 'missing responses'; Reply = '{}' }
        @{ Name = 'an empty response list'; Reply = '{"responses":[]}' }
        @{ Name = 'a different response ID'; Reply = '{"responses":[{"id":"other","status":200,"body":{"value":[]}}]}' }
        @{ Name = 'duplicate response IDs'; Reply = '{"responses":[{"id":"members","status":200,"body":{"value":[]}},{"id":"members","status":200,"body":{"value":[]}}]}' }
        @{ Name = 'a missing status'; Reply = '{"responses":[{"id":"members","body":{"value":[]}}]}' }
        @{ Name = 'a missing body'; Reply = '{"responses":[{"id":"members","status":200}]}' }
        @{ Name = 'a missing collection'; Reply = '{"responses":[{"id":"members","status":200,"body":{}}]}' }
        @{ Name = 'a null collection'; Reply = '{"responses":[{"id":"members","status":200,"body":{"value":null}}]}' }
        @{ Name = 'an object instead of a collection'; Reply = '{"responses":[{"id":"members","status":200,"body":{"value":{"id":"wrong-shape"}}}]}' }
        @{ Name = 'an error body with status 200'; Reply = '{"responses":[{"id":"members","status":200,"body":{"value":[],"error":{"code":"BadResponse","message":"fixture error"}}}]}' }
    ) {
        $script:Replies.Enqueue($Reply)
        $Output = [System.Collections.Generic.List[object]]::new()

        { New-GraphBulkRequest @script:Parameters | ForEach-Object { $Output.Add($_) } } |
            Should -Throw '*pagination*members*'

        $Output.Count | Should -Be 0
        $script:Tenant.GraphErrorCount | Should -Be 4
        $script:Tenant.LastGraphError | Should -BeLike '*pagination*members*'
        Should -Invoke Update-AzDataTableEntity -Times 1 -Exactly
    }

    It 'aggregates three pages and clears the previous tenant error on success' {
        $script:Replies.Enqueue(@'
{"responses":[{"id":"members","status":200,"body":{"value":[{"id":"second"}],"@odata.nextLink":"https://graph.microsoft.com/v1.0/groups/fixture/members?page=3"}}]}
'@)
        $script:Replies.Enqueue(@'
{"responses":[{"id":"members","status":200,"body":{"value":[{"id":"third"}]}}]}
'@)

        $Result = @(New-GraphBulkRequest @script:Parameters)

        $Result.Count | Should -Be 1
        $Result[0].status | Should -Be 200
        $Result[0].body.value.id | Should -Be @('first', 'second', 'third')
        $script:SentRequests[1].requests[0].url | Should -Be '/groups/fixture/members?page=2'
        $script:SentRequests[2].requests[0].url | Should -Be '/groups/fixture/members?page=3'
        $script:SentRequests[1].requests[0].method | Should -Be 'GET'
        $script:Tenant.LastGraphError | Should -Be ''
        $script:Tenant.GraphErrorCount | Should -Be 3
        Should -Invoke Update-AzDataTableEntity -Times 1 -Exactly
        Should -Invoke Invoke-CIPPRestMethod -Times 3 -Exactly
    }

    It 'accepts an empty final page' {
        $script:Replies.Enqueue('{"responses":[{"id":"members","status":200,"body":{"value":[]}}]}')

        $Result = New-GraphBulkRequest @script:Parameters

        @($Result.body.value).Count | Should -Be 1
        $Result.body.value[0].id | Should -Be 'first'
        $script:Tenant.LastGraphError | Should -Be ''
        Should -Invoke Invoke-CIPPRestMethod -Times 2 -Exactly
    }

    It 'continues past an empty intermediate page' {
        $script:Replies.Enqueue(@'
{"responses":[{"id":"members","status":200,"body":{"value":[],"@odata.nextLink":"https://graph.microsoft.com/beta/groups/fixture/members?page=3"}}]}
'@)
        $script:Replies.Enqueue('{"responses":[{"id":"members","status":200,"body":{"value":[{"id":"last"}]}}]}')

        $Result = New-GraphBulkRequest @script:Parameters

        $Result.body.value.id | Should -Be @('first', 'last')
        Should -Invoke Invoke-CIPPRestMethod -Times 3 -Exactly
    }

    It 'keeps independent batch IDs separate while respecting NoPaginateIds' {
        $script:Parameters.Requests = @(
            @{ id = 'members'; method = 'GET'; url = '/groups/fixture/members' }
            @{ id = 'owners'; method = 'GET'; url = '/groups/fixture/owners' }
            @{ id = 'skipped'; method = 'GET'; url = '/users' }
        )
        $script:Parameters.NoPaginateIds = @('skipped')
        $script:Replies.Clear()
        $script:Replies.Enqueue(@'
{"responses":[{"id":"owners","status":200,"body":{"value":[{"id":"owner-first"}],"@odata.nextLink":"https://graph.microsoft.com/beta/groups/fixture/owners?page=2"}},{"id":"skipped","status":200,"body":{"value":[{"id":"skip-first"}],"@odata.nextLink":"https://graph.microsoft.com/beta/users?page=2"}},{"id":"members","status":200,"body":{"value":[{"id":"member-first"}],"@odata.nextLink":"https://graph.microsoft.com/beta/groups/fixture/members?page=2"}}]}
'@)
        $script:Replies.Enqueue('{"responses":[{"id":"owners","status":200,"body":{"value":[{"id":"owner-last"}]}}]}')
        $script:Replies.Enqueue('{"responses":[{"id":"members","status":200,"body":{"value":[{"id":"member-last"}]}}]}')

        $Result = @(New-GraphBulkRequest @script:Parameters)

        $Result.Count | Should -Be 3
        ($Result | Where-Object id -eq 'members').body.value.id | Should -Be @('member-first', 'member-last')
        ($Result | Where-Object id -eq 'owners').body.value.id | Should -Be @('owner-first', 'owner-last')
        ($Result | Where-Object id -eq 'skipped').body.value.id | Should -Be 'skip-first'
        ($Result | Where-Object id -eq 'skipped').body.'@odata.nextLink' | Should -Be 'https://graph.microsoft.com/beta/users?page=2'
        $script:SentRequests[1].requests[0].id | Should -Be 'owners'
        $script:SentRequests[2].requests[0].id | Should -Be 'members'
        Should -Invoke Invoke-CIPPRestMethod -Times 3 -Exactly
    }

    It 'preserves transport exceptions and records the tenant failure' {
        Mock Invoke-CIPPRestMethod { throw 'fixture transport failure' } -ParameterFilter { $Body -like '*page=2*' }

        { New-GraphBulkRequest @script:Parameters } | Should -Throw '*fixture transport failure*'

        $script:Tenant.LastGraphError | Should -Be 'fixture transport failure'
        $script:Tenant.GraphErrorCount | Should -Be 4
        Should -Invoke Update-AzDataTableEntity -Times 1 -Exactly
    }
}
