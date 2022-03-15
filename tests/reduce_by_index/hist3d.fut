-- ==
-- input { [[[1,2,3],[4,5,6],[7,8,9]],[[10,20,30],[40,50,60],[70,80,90]]] }
-- output {
--   [[[1i32, 2i32, 3i32], [4i32, 5i32, 6i32], [7i32, 8i32, 9i32]],
--    [[10i32, 20i32, 30i32], [40i32, 1387i32, 60i32], [70i32, 80i32, 90i32]]]
-- }

def main [n][m][o] (xss: *[n][m][o]i32) =
  reduce_by_index_3d xss (+) 0 [(1, 1, 1), (1,-1, 1)] [1337, 0]