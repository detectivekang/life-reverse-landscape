[PNG 교체 방법]
1) assets/ 아래 같은 위치/이름으로 .png를 넣는다.  예) assets/icons/box.png, assets/swords/fire.png, assets/life/avatar_05.png, assets/sky/far.png
2) python update_manifest.py 실행 (assets/manifest.js 갱신)
3) 배포. PNG가 있으면 PNG, 없으면 SVG, 둘 다 없으면 이모지로 표시됨.

[규격]
icons 128x128 / life 256x256 / swords 256x256(칼끝 우상향) / sprites/pig 가로 4프레임 / sprites/walk_0~5 가로 6프레임 / sprites/bus,taxi 128x72
sky/far·mid·near 는 좌우 이음새가 이어지는 투명 PNG(건물 실루엣). 색은 게임이 입힘.
