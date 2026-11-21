import Foundation
import Testing
@testable import AmbitKit

// Reference values from `openssl passwd -1 / -5 / -6 -salt SALT PASSWORD` (OpenSSL 4.1.0).
// The passwords are made up for the test. They cover the block boundaries of each hash
// (16, 32 and 64 bytes), multi-byte UTF-8, and salts shorter and longer than the limit.
private let references: [(password: String, salt: String, scheme: Int, expected: String)] = [
        ("test password", "abcdefgh", 1, "$1$abcdefgh$Cq1YRAf.QXEsRsFFce/.F0"),
        ("test password", "Zq.7/aB1cD2eF3gH", 1, "$1$Zq.7/aB1$q/ApBADOA1Xv//iyy/n9i1"),
        ("test password", "x", 1, "$1$x$JqCPNDmZUzx/P8Hun5b7X."),
        ("test password", "abcdefgh", 5, "$5$abcdefgh$6tq8p6LhUUVxOuvmdPwyMbL06DwgG.rVrYZ9PbUucj6"),
        ("test password", "Zq.7/aB1cD2eF3gH", 5, "$5$Zq.7/aB1cD2eF3gH$nsTknEIfHq71w.8QKIOqWRyAKpZJe2Pz2TSBGsUH/z/"),
        ("test password", "x", 5, "$5$x$bSADdamPJb4hnQPNczNg8XVML0rDbauLo.fX2xFMO6."),
        ("test password", "abcdefgh", 6, "$6$abcdefgh$B5Cs2daEj8iFUqSTHSxQ.9WcRJs7uzueVHU./UjUW9NIyxpQMyNXeL2L4003eI9nLbCeL7Wf/t7EPEvP.IZZO0"),
        ("test password", "Zq.7/aB1cD2eF3gH", 6, "$6$Zq.7/aB1cD2eF3gH$DlPlsx4jc0d/Z10.W3uhbtoUD4WCcxUy70FtVvto.WYVI6Vc2afk0ZZ0U6LGrCAbcvIujZgFXQ.0yxrmZwu98."),
        ("test password", "x", 6, "$6$x$eW0Aq4.5/rg2/vUZ/CJpTQ5KV/uI7E4P5fEZi730XesZYR/jXrbzsSYgIEBfMDaWjVmV8zPhFbaAcRfgMK1yz/"),
        ("a", "abcdefgh", 1, "$1$abcdefgh$jUYc1Xi7pkozuzWQ0Dft71"),
        ("a", "Zq.7/aB1cD2eF3gH", 1, "$1$Zq.7/aB1$rraB9Evxc2BfVnMbz3sww0"),
        ("a", "x", 1, "$1$x$P8VObTrxaqT4VBmnH06P8."),
        ("a", "abcdefgh", 5, "$5$abcdefgh$GzAL/HPD/MYJIjVUUnvBTiqueLrt/LVxJEZtz0qaNX2"),
        ("a", "Zq.7/aB1cD2eF3gH", 5, "$5$Zq.7/aB1cD2eF3gH$o.gi4mp3RIffGxGKJ7dKoZG6PC1.Bx8oGFC1rW32m27"),
        ("a", "x", 5, "$5$x$85aGabM7xSEYcp0wkefjwtqWAYi1Rrq3b01Gtllmmh7"),
        ("a", "abcdefgh", 6, "$6$abcdefgh$GjMgmmowSihU3X8xhdMxaCaEziO5NUh/IZqYnnZhN1j7.JYnm2e5BnPfWNUdj17OlEroBdrPtMnfsmwWCrkw70"),
        ("a", "Zq.7/aB1cD2eF3gH", 6, "$6$Zq.7/aB1cD2eF3gH$GlFxgbcC8Fky9yWJ1OAww9R5f.qcJDloQIVdxwrOv0njEuuYqsbLHiPQB4n86K8rqyE2yXFjZcH/Ryz8Uw/tO."),
        ("a", "x", 6, "$6$x$6Zqbz8j5rMHIeJ1ujjjFXuZXSa/VORj.fVUEQcJc.rjR9.wCKlhZuymRQLtIEzcxNmqwX/fRNvM45BbvFayY51"),
        ("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "abcdefgh", 1, "$1$abcdefgh$qZQJZIj/wBFysso0hpBg61"),
        ("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "Zq.7/aB1cD2eF3gH", 1, "$1$Zq.7/aB1$OWO2VAVsKy5ObONh65br6."),
        ("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "x", 1, "$1$x$OuQPGwrCpQYx4vTr3m3Xp1"),
        ("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "abcdefgh", 5, "$5$abcdefgh$lZK56QNQPN6R4.IHMn4/mfyfL52QchLo7qGrBRL5dp0"),
        ("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "Zq.7/aB1cD2eF3gH", 5, "$5$Zq.7/aB1cD2eF3gH$TUcJqF87W6tPqFojirDa5/StNHDR4aWpR1g.3F6sDdD"),
        ("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "x", 5, "$5$x$QK2FFK6DEHO24l2g2noiqNQ8zGxLh8slXkuAiuMgQk/"),
        ("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "abcdefgh", 6, "$6$abcdefgh$Nvk31TZoEuTUq.MkdUx.GD6fBjYTEdPeTnNMiXgmXEWIVcWa7UP3XG/WNbNPQ2jsb6gGqGU9Q83PpnzMBZMox."),
        ("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "Zq.7/aB1cD2eF3gH", 6, "$6$Zq.7/aB1cD2eF3gH$dYETjOiZnQN2uGeqv.EOuzkGq8zX4E1NgTTNAcQzk7rn7TNc39Fs30gZ5vkAWYMHrQlEwxplMf6SpRJGMMPrl/"),
        ("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx", "x", 6, "$6$x$PiOn8OevXzSj8dB5pAK0evSknJ2MpYH59rUG2piaifA.a7eP3BfpF6BBreIeKsaFUAGDQaCKwbgx5wRia.fg.0"),
        ("pässwörd ünïcode", "abcdefgh", 1, "$1$abcdefgh$jUkI6CxX2BSTTS3580VBm/"),
        ("pässwörd ünïcode", "Zq.7/aB1cD2eF3gH", 1, "$1$Zq.7/aB1$JBvqNZzhwHGScNRM0zByL."),
        ("pässwörd ünïcode", "x", 1, "$1$x$761aEUjOkqNQJrDWIQjLF."),
        ("pässwörd ünïcode", "abcdefgh", 5, "$5$abcdefgh$lRE7rW7d.1LdSfbCcYx/eIB/XwQz1qk12mr3Mfz1GrD"),
        ("pässwörd ünïcode", "Zq.7/aB1cD2eF3gH", 5, "$5$Zq.7/aB1cD2eF3gH$xIO1h1a12GnhHyR2Z5HMDX40CXnwVbk5in5B44zb.m4"),
        ("pässwörd ünïcode", "x", 5, "$5$x$tP4shIaS1zEeiHDNo3qm6D5onET3KBkBnhIHybDmmF."),
        ("pässwörd ünïcode", "abcdefgh", 6, "$6$abcdefgh$lsyatYVCQ8pI9RDYrT.yq.aRdFAV0i/3ariD.Q3b7eNocCQd9PQVnxmzVqNCUGvVqWvQ8RrJS1FXhvAL5P3HD0"),
        ("pässwörd ünïcode", "Zq.7/aB1cD2eF3gH", 6, "$6$Zq.7/aB1cD2eF3gH$xI8JA1Pvvf3EEbCfaGq0/HFer6/ANYHvqAzEEaYzDfVhJB14U4tNpYwheDnHwETraexpS02mYyMoJPy8jyFFq."),
        ("pässwörd ünïcode", "x", 6, "$6$x$9iavFg9moHlNKhbNioHV3/aN50mVwvy83aPtZTpxYCHfWO9GZkEYgeP9dqimZa8gP1YTA9LHRwdQqRxXWTMFH/"),
        ("sixteen-byte-pw!", "abcdefgh", 1, "$1$abcdefgh$DH7hqv7Qt0z0rBrRjdXtj1"),
        ("sixteen-byte-pw!", "Zq.7/aB1cD2eF3gH", 1, "$1$Zq.7/aB1$Sy8EUo0AafLKU6ZvxNKRD0"),
        ("sixteen-byte-pw!", "x", 1, "$1$x$bd6rJa..PGFA8opwpBftq."),
        ("sixteen-byte-pw!", "abcdefgh", 5, "$5$abcdefgh$ybb1MEC0CFBc/cWrNqVybSxLJS9k9m0dR1qOXxq3kZ1"),
        ("sixteen-byte-pw!", "Zq.7/aB1cD2eF3gH", 5, "$5$Zq.7/aB1cD2eF3gH$jqowSX7UZtLdt5L7/xVXqePyROOwhO2gnzb7k.Ym8W4"),
        ("sixteen-byte-pw!", "x", 5, "$5$x$OZOcCM8eDjcCr0CWWMj3R3gnPyTzGMdNbSXwWUJv3e4"),
        ("sixteen-byte-pw!", "abcdefgh", 6, "$6$abcdefgh$wqBOxEZ.3nuymrxqB6BvM7EDowe/db./6LRoOoEU7XrcEQNtUBEblhlQ/0tRQu5Gl7V5v5WWjXwlgD1zSO0cH1"),
        ("sixteen-byte-pw!", "Zq.7/aB1cD2eF3gH", 6, "$6$Zq.7/aB1cD2eF3gH$WpV.7fyzHk6BVFHgOJ0tO/8w3gTqYrBppiLbkhtgbaX0LtR1Gtr/HrPYeOzoH.YXJLa.IWJkWy6Ft2UcFv8350"),
        ("sixteen-byte-pw!", "x", 6, "$6$x$KZouvZf7ga4.Wm.HhZ12wSvMfTQwDpT/4OGdh6OC9cJpPcTJWvbU4F6/Y7kfNuzqjUlEbX.QmaCuagTXxjwJU."),
        ("yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy", "abcdefgh", 1, "$1$abcdefgh$2DnBIpeEpuszEWoZpv6iO/"),
        ("yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy", "Zq.7/aB1cD2eF3gH", 1, "$1$Zq.7/aB1$1dpQoZkOwA9sjsZw2fDMa1"),
        ("yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy", "x", 1, "$1$x$ruQ.4yFtElL4tuxF0PkCA."),
        ("yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy", "abcdefgh", 5, "$5$abcdefgh$DvdZWrWFCxK4JwXIu/nwxQsRf07rCcHvAtLc1VZzuh9"),
        ("yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy", "Zq.7/aB1cD2eF3gH", 5, "$5$Zq.7/aB1cD2eF3gH$mnuUN5zd7/nQUlZhWDN/oDKyU/Hc6c0ggNVYjSrJHG2"),
        ("yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy", "x", 5, "$5$x$GjoWGwCFNB058TrLv.CNKM4G/0/1p2OogaBx4Ch3AE8"),
        ("yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy", "abcdefgh", 6, "$6$abcdefgh$v2lqyL74hDzvySQkrfWjyuwk2TlVfKxmg7XSXhD/kz411GBmk8hf6rTeImp1.WbXJrjOgrQ3X14NJsz.sZxxw0"),
        ("yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy", "Zq.7/aB1cD2eF3gH", 6, "$6$Zq.7/aB1cD2eF3gH$T36reOfMzHa2P4wO1MekPsOO3mfc6DJZSW/Lim965UEGkSG69sRegWyGyV07TcFL3f/tkw2eZ3I9m5B6pZez9."),
        ("yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy", "x", 6, "$6$x$nI6CuyTUsQCM3v.Yyu.kkxF9L2JTDHmPIkKjRIQdfPp2oS4eF6e/nTnZI2t6z1I.DbIBL7oEJYKnfI6ykqbvG/"),
]

@Suite struct UnixCryptTests {
    @Test func matchesOpenSSLForEveryScheme() throws {
        #expect(references.count == 54)
        for reference in references {
            let scheme = try #require(UnixCrypt.Scheme(rawValue: reference.scheme))
            let hash = try UnixCrypt.hash(password: reference.password, salt: reference.salt, scheme: scheme)
            #expect(hash == reference.expected, "scheme \(reference.scheme), salt \(reference.salt), \(reference.password.utf8.count) bytes")
        }
    }

    @Test func rejectsSaltsItCannotHonour() {
        #expect(throws: UnixCrypt.InvalidSalt()) { try UnixCrypt.hash(password: "p", salt: "", scheme: .sha256) }
        #expect(throws: UnixCrypt.InvalidSalt()) { try UnixCrypt.hash(password: "p", salt: "ab$cd", scheme: .sha512) }
        #expect(throws: UnixCrypt.InvalidSalt()) { try UnixCrypt.hash(password: "p", salt: "rounds=10", scheme: .sha256) }
    }
}
