using Ferrite, BlockArrays, SparseArrays, Test

@testset "BlockArrays.jl extension" begin
    grid = generate_grid(Triangle, (10, 10))

    dh = DofHandler(grid)
    ip = Lagrange{RefTriangle, 1}()
    add!(dh, :u, ip^2)
    add!(dh, :p, ip)
    close!(dh)
    renumber!(dh, DofOrder.FieldWise())
    nd = ndofs(dh) ÷ 3

    ch = ConstraintHandler(dh)
    periodic_faces = collect_periodic_facets(grid, "top", "bottom")
    add!(ch, PeriodicDirichlet(:u, periodic_faces))
    add!(ch, Dirichlet(:u, union(getfacetset(grid, "left"), getfacetset(grid, "top")), (x, t) -> [0, 0]))
    add!(ch, Dirichlet(:p, getfacetset(grid, "left"), (x, t) -> 0))
    close!(ch)
    update!(ch, 0)

    K = allocate_matrix(dh, ch)
    f = zeros(axes(K, 1))
    # TODO: allocate_matrix(BlockMatrix, ...) should work and default to field blocking
    bsp = BlockSparsityPattern([2nd, 1nd])
    add_sparsity_entries!(bsp, dh, ch)
    KB = allocate_matrix(BlockMatrix, bsp)
    @test KB isa BlockMatrix
    @test blocksize(KB) == (2, 2)
    @test size(KB[Block(1), Block(1)]) == (2nd, 2nd)
    @test size(KB[Block(2), Block(1)]) == (1nd, 2nd)
    @test size(KB[Block(1), Block(2)]) == (2nd, 1nd)
    @test size(KB[Block(2), Block(2)]) == (1nd, 1nd)
    fB = similar(KB, axes(KB, 1))

    # Test the pattern
    fill!(K.nzval, 1)
    foreach(x -> fill!(x.nzval, 1), blocks(KB))
    @test K == KB

    # Zeroing out in start_assemble
    assembler = start_assemble(K, f)
    @test iszero(K)
    @test iszero(f)
    block_assembler = start_assemble(KB, fB)
    @test iszero(KB)
    @test iszero(fB)

    # Assembly procedure
    npc = ndofs_per_cell(dh)
    for cc in CellIterator(dh)
        ke = rand(npc, npc)
        fe = rand(npc)
        dofs = celldofs(cc)
        # Standard assemble
        assemble!(assembler, dofs, ke, fe)
        assemble!(block_assembler, dofs, ke, fe)
        # Assemble with local condensation of constraints
        let ke = copy(ke), fe = copy(fe)
            apply_assemble!(assembler, ch, dofs, ke, fe)
        end
        let ke = copy(ke), fe = copy(fe)
            apply_assemble!(block_assembler, ch, dofs, ke, fe)
        end
    end
    @test K ≈ KB
    @test f ≈ fB

    # Global application of BC not supported yet
    @test_throws ErrorException apply!(KB, fB, ch)

    # Custom blocking
    perm = invperm([ch.free_dofs; ch.prescribed_dofs])
    renumber!(dh, ch, perm)
    nfree = length(ch.free_dofs)
    npres = length(ch.prescribed_dofs)
    K = allocate_matrix(dh, ch)
    block_sizes = [nfree, npres]
    bsp = BlockSparsityPattern(block_sizes)
    add_sparsity_entries!(bsp, dh, ch)
    KB = allocate_matrix(BlockMatrix, bsp)
    @test blocksize(KB) == (2, 2)
    @test size(KB[Block(1), Block(1)]) == (nfree, nfree)
    @test size(KB[Block(2), Block(1)]) == (npres, nfree)
    @test size(KB[Block(1), Block(2)]) == (nfree, npres)
    @test size(KB[Block(2), Block(2)]) == (npres, npres)
    # Test the pattern
    fill!(K.nzval, 1)
    foreach(x -> fill!(x.nzval, 1), blocks(KB))
    @test K == KB
end
